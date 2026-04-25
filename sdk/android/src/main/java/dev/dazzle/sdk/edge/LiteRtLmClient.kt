// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

package dev.dazzle.sdk.edge

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.DazzleException
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.ToolDeclaration
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.io.File

/**
 * Default [LLMClient] implementation that runs Gemma / Llama / Qwen
 * on-device via LiteRT-LM. Used by the Layer 3 `DazzleEdge` bundle when
 * the consumer opts into `.liteRTLM` as the backend.
 *
 * ## Adding to your app
 *
 * This class is `compileOnly` in the Dazzle AAR so downstream consumers
 * that bring their own LLM (cloud API, Foundation Models, llama.cpp,
 * custom adapter) pay zero cost. Apps that actually use `LiteRtLmClient`
 * must add the runtime dep to their own `build.gradle.kts`:
 *
 * ```kotlin
 * dependencies {
 *     implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")
 * }
 * ```
 *
 * Plus ensure `android:extractNativeLibs="true"` is NOT set (AGP default
 * is already correct) and that the minSdk >= 26.
 *
 * ## What this adapter DOES
 *
 * - Loads a `.litertlm` model file via LiteRT-LM's `Engine` API
 * - Translates `[Message]` → the runtime's `ConversationConfig` + user
 *   message. The runtime handles ChatML / Gemma / Llama chat templating
 *   internally so we don't duplicate prompt-format knowledge here.
 * - Streams completions as `Delta.Text` chunks; emits `Delta.End` at the
 *   terminal.
 * - Cancellation: the collecting coroutine's cancellation propagates
 *   through the runtime's Flow as a normal coroutine cancellation.
 *
 * ## Tool-calling
 *
 * The adapter parses the three mainstream on-device tool-call dialects
 * out of the box: Gemma (`<tool_call>{…}</tool_call>`), Llama 3.x
 * (`<|python_tag|>{…}<|eom_id|>`), and Qwen 2.5 (same XML markers as
 * Gemma, different prompt framing). When the caller passes a non-empty
 * `tools` list:
 *
 * 1. The adapter appends a dialect-specific `# Tools` section to the
 *    system prompt describing each function in the format the model
 *    was fine-tuned on.
 * 2. Streamed output is piped through [ToolCallParser], which emits
 *    `Delta.ToolCallStart` + `Delta.ToolCallArgs` for tool blocks and
 *    forwards plain text verbatim as `Delta.Text`.
 * 3. `complete()` collects the same stream and assembles the final
 *    [Completion.ToolCalls] when the model invoked at least one tool.
 *
 * The exact dialect is picked by [toolCallSyntax]; `ToolCallSyntax.auto`
 * infers it from the model filename (gemma-/llama-/qwen-).
 */
class LiteRtLmClient(
    private val modelFile: File,
    override val modelId: String = modelFile.nameWithoutExtension,
    context: Context,
    /** LiteRT-LM backend. Default CPU matches the experiment apps —
     *  safer memory profile on 6 GB phones when the 2.4 GB model is
     *  already resident. Pass `Backend.GPU()` when on a Pixel 9 Pro
     *  or similar with enough VRAM headroom. */
    backend: Backend = Backend.CPU(),
    private val systemPrompt: String = "You are a helpful on-device AI assistant.",
    private val temperature: Double = 0.01,
    private val topK: Int = 1,
    private val topP: Double = 1.0,
    private val maxTokens: Int = 512,
    /** Tool-call dialect expected by the model. `auto` detects from the
     *  filename (gemma-/llama-/qwen-); any other value forces a specific
     *  parser + prompt template regardless of the filename. */
    toolCallSyntax: ToolCallSyntax = ToolCallSyntax.auto,
) : LLMClient {

    private val syntax: ToolCallSyntax = when (toolCallSyntax) {
        ToolCallSyntax.auto -> ToolCallPrompts.detectFromFilename(modelFile.name)
        else                -> toolCallSyntax
    }

    private val engine: Engine = Engine(
        EngineConfig(
            modelPath = modelFile.absolutePath,
            backend = backend,
            cacheDir = context.cacheDir.path,
        )
    )

    init {
        try {
            engine.initialize()
        } catch (t: Throwable) {
            throw DazzleException.ModelLoadFailed(modelId, t)
        }
    }

    /**
     * One-shot generation. Returns either `Completion.Text` or
     * `Completion.ToolCalls` depending on what the model emitted.
     * When `tools` is non-empty the dialect-specific `# Tools` block
     * is appended to the system prompt and the stream output goes
     * through [ToolCallParser] before being assembled.
     */
    override suspend fun complete(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Completion {
        val text = StringBuilder()
        val partialArgs = LinkedHashMap<String, StringBuilder>()
        val callNames   = LinkedHashMap<String, String>()
        stream(messages, tools).collect { d ->
            when (d) {
                is Delta.Text          -> text.append(d.chunk)
                is Delta.ToolCallStart -> {
                    callNames[d.id]   = d.name
                    partialArgs[d.id] = StringBuilder()
                }
                is Delta.ToolCallArgs  -> {
                    partialArgs.getOrPut(d.id) { StringBuilder() }.append(d.argsChunk)
                }
                Delta.End              -> Unit
            }
        }
        return if (callNames.isNotEmpty()) {
            val calls = callNames.map { (id, name) ->
                ToolCall(id = id, name = name, arguments = partialArgs[id]?.toString() ?: "{}")
            }
            Completion.ToolCalls(
                Message(role = Role.assistant, content = "", toolCalls = calls)
            )
        } else {
            Completion.Text(Message(role = Role.assistant, content = text.toString().trim()))
        }
    }

    override fun stream(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Flow<Delta> = flow {
        val userMessage = assembleUserMessage(messages)
        val sysPrompt   = augmentedSystemPrompt(messages, tools)
        val convCfg = ConversationConfig(
            systemInstruction = Contents.of(sysPrompt),
            samplerConfig = SamplerConfig(
                topK = topK,
                topP = topP,
                temperature = temperature,
            ),
        )
        val parser = ToolCallParser(syntax)
        engine.createConversation(convCfg).use { conv ->
            conv.sendMessageAsync(userMessage).collect { chunk ->
                val text = chunk.toString()
                if (text.isNotEmpty()) {
                    for (d in parser.process(text)) emit(d)
                }
            }
        }
        for (d in parser.flush()) emit(d)
        emit(Delta.End)
    }

    override fun close() {
        runCatching { engine.close() }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /**
     * Pull the most recent `Role.system` turn's content if any; otherwise
     * fall back to this client's [systemPrompt]. We honour the caller's
     * per-turn system prompt so the same LLMClient instance serves
     * different agents without reconfiguration.
     */
    private fun effectiveSystemPrompt(messages: List<Message>): String =
        messages.lastOrNull { it.role == Role.system }?.content ?: systemPrompt

    /**
     * Collapse the conversation into a single user message the runtime
     * can consume. The LiteRT-LM `Conversation.sendMessage` API is
     * stateless per call, so we flatten user/assistant/tool turns into
     * a plain-text transcript + the latest user turn as the "send".
     *
     * This is a deliberately simple heuristic. A future version will
     * use the runtime's multi-turn `createConversation` API with
     * history replay so we don't pay the full-prompt cost every turn.
     */
    private fun assembleUserMessage(messages: List<Message>): String {
        val turns = messages.filter { it.role != Role.system }
        if (turns.isEmpty()) return ""
        // If the last non-system turn is a user turn, use it directly.
        // Otherwise assemble a transcript (unusual — the Agent always
        // calls us after appending a user turn).
        if (turns.size == 1 && turns.first().role == Role.user) {
            return turns.first().content
        }
        return buildString {
            for (t in turns.dropLast(1)) {
                val prefix = when (t.role) {
                    Role.user -> "User"
                    Role.assistant -> "Assistant"
                    Role.tool -> "Tool"
                    else -> t.role.name
                }
                appendLine("$prefix: ${t.content}")
            }
            append(turns.last().content)
        }
    }

    /**
     * Build the system prompt that is actually sent to the runtime: the
     * effective user-supplied prompt + a dialect-specific `# Tools`
     * block listing every [ToolDeclaration]. Empty tools list means the
     * user prompt is passed through unchanged.
     */
    private fun augmentedSystemPrompt(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): String {
        val base = effectiveSystemPrompt(messages)
        if (tools.isEmpty()) return base
        return base + ToolCallPrompts.renderToolsSection(tools, syntax)
    }
}
