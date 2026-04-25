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

import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.DazzleException
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.ToolDeclaration
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import java.io.File

/**
 * [LLMClient] that runs on-device inference via the embedded
 * llama.cpp (bundled inside `libdazzle.so`). Loads GGUF weight
 * files — every model packaged for llama.cpp on Hugging Face works:
 * Gemma 2/3, Llama 3.x, Qwen 2.5, Phi-4, DeepSeek-R1 distills,
 * Mistral, Mixtral, etc.
 *
 * ## Usage
 *
 * ```kotlin
 * val llm = LlamaCppClient(
 *     modelFile = File(context.filesDir, "qwen2.5-1.5b.Q4_K_M.gguf"),
 * )
 * val agent = DazzleEdge.chatAgent(context, llm = llm)
 * agent.send("Explain quantisation in one sentence.")
 * ```
 *
 * ## Tool-calling
 *
 * Reuses the same [ToolCallSyntax] / [ToolCallParser] pipeline the
 * `LiteRtLmClient` uses, so Gemma / Llama / Qwen tool output is
 * parsed into `Delta.ToolCallStart` / `Delta.ToolCallArgs` without
 * extra wiring.
 *
 * ## Threading
 *
 * llama.cpp's decode loop is stateful and single-threaded — the
 * class serialises every `complete` / `stream` invocation through
 * [Dispatchers.Default]. Cancelling the collecting coroutine
 * propagates into the native callback and stops the generator at
 * the next token boundary.
 */
class LlamaCppClient(
    private val modelFile: File,
    override val modelId: String = modelFile.nameWithoutExtension,
    private val systemPrompt: String = "You are a helpful on-device AI assistant.",
    private val temperature: Float = 0.7f,
    private val topP: Float = 0.95f,
    private val maxTokens: Int = 512,
    nCtx: Int = 2048,
    nThreads: Int = 4,
    nGpuLayers: Int = 0,
    private val seed: Int = 0xD4_77_1E,
    toolCallSyntax: ToolCallSyntax = ToolCallSyntax.auto,
    /** Dispatcher used for blocking native work. Tests inject a
     *  confined dispatcher; production defaults to Dispatchers.Default. */
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) : LLMClient {

    private val syntax: ToolCallSyntax = when (toolCallSyntax) {
        ToolCallSyntax.auto -> ToolCallPrompts.detectFromFilename(modelFile.name)
        else                -> toolCallSyntax
    }

    /** Native model handle (opaque). Set in the init block, freed
     *  in [close]. Non-zero while valid. */
    private var modelHandle: Long = 0
    private var ctxHandle: Long = 0

    init {
        if (!modelFile.isFile) {
            throw DazzleException.ModelLoadFailed(modelId,
                RuntimeException("GGUF file not found: ${modelFile.absolutePath}"))
        }
        LlamaNative.nBackendInit()
        modelHandle = LlamaNative.nLoadModel(modelFile.absolutePath, nGpuLayers)
        if (modelHandle == 0L) {
            throw DazzleException.ModelLoadFailed(modelId,
                RuntimeException("nLoadModel returned 0 — inspect logcat for llama.cpp diagnostics"))
        }
        ctxHandle = LlamaNative.nNewContext(modelHandle, nCtx, nThreads)
        if (ctxHandle == 0L) {
            LlamaNative.nFreeModel(modelHandle)
            modelHandle = 0
            throw DazzleException.ModelLoadFailed(modelId,
                RuntimeException("nNewContext returned 0"))
        }
    }

    // ── LLMClient ────────────────────────────────────────────────────────

    override suspend fun complete(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Completion {
        var text = StringBuilder()
        val callNames = LinkedHashMap<String, String>()
        val callArgs  = mutableMapOf<String, StringBuilder>()
        stream(messages, tools).collect { d ->
            when (d) {
                is Delta.Text          -> text.append(d.chunk)
                is Delta.ToolCallStart -> {
                    callNames[d.id] = d.name
                    callArgs[d.id]  = StringBuilder()
                }
                is Delta.ToolCallArgs  -> {
                    callArgs.getOrPut(d.id) { StringBuilder() }.append(d.argsChunk)
                }
                Delta.End              -> Unit
            }
        }
        return if (callNames.isNotEmpty()) {
            val calls = callNames.map { (id, name) ->
                ToolCall(id = id, name = name, arguments = callArgs[id]?.toString() ?: "{}")
            }
            Completion.ToolCalls(Message(role = Role.assistant, content = "", toolCalls = calls))
        } else {
            Completion.Text(Message(role = Role.assistant, content = text.toString().trim()))
        }
    }

    override fun stream(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Flow<Delta> = flow {
        val prompt = assemblePrompt(messages, tools)
        val parser = ToolCallParser(syntax)

        // Bridge between the native callback (runs on our blocking
        // thread) and the Flow collector: a bounded channel so back-
        // pressure from the consumer naturally stops the generator.
        val channel = Channel<Delta>(capacity = 64)

        var rc = 0
        val nativeResult = withContext(dispatcher) {
            val cb = LlamaTokenCallback { piece ->
                for (d in parser.process(piece)) {
                    val sendResult = channel.trySend(d)
                    if (sendResult.isFailure && !sendResult.isSuccess) {
                        // Channel closed (cancellation) — stop decoding.
                        return@LlamaTokenCallback false
                    }
                }
                true
            }
            val code = LlamaNative.nGenerate(
                ctxHandle, prompt, maxTokens,
                temperature, topP, seed, cb,
            )
            // Flush tool-call tail before closing the channel.
            for (d in parser.flush()) channel.trySend(d)
            channel.trySend(Delta.End)
            channel.close()
            code
        }
        rc = nativeResult

        // Replay every Delta from the channel to the caller.
        for (d in channel) emit(d)

        if (rc < 0 && rc != -5 /* DAZZLE_LLAMA_E_CANCELLED */) {
            throw LlamaCppException.GenerationFailed(rc)
        }
    }.flowOn(dispatcher)

    override fun close() {
        if (ctxHandle != 0L) {
            LlamaNative.nFreeContext(ctxHandle)
            ctxHandle = 0
        }
        if (modelHandle != 0L) {
            LlamaNative.nFreeModel(modelHandle)
            modelHandle = 0
        }
    }

    protected fun finalize() { close() }

    // ── Helpers ──────────────────────────────────────────────────────────

    private fun assemblePrompt(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): String {
        val baseSystem = messages.lastOrNull { it.role == Role.system }?.content ?: systemPrompt
        val system = baseSystem + ToolCallPrompts.renderToolsSection(tools, syntax)
        val turns = messages.filter { it.role != Role.system }
        val sb = StringBuilder()
        sb.append("<|system|>\n").append(system).append('\n')
        for (t in turns) {
            val label = when (t.role) {
                Role.user      -> "user"
                Role.assistant -> "assistant"
                Role.tool      -> "tool"
                Role.system    -> continue
            }
            sb.append("<|").append(label).append("|>\n").append(t.content).append('\n')
        }
        sb.append("<|assistant|>\n")
        return sb.toString()
    }
}

/** Adapter-level errors raised by [LlamaCppClient]. */
sealed class LlamaCppException(msg: String) : RuntimeException(msg) {
    class GenerationFailed(val code: Int)
        : LlamaCppException("dazzle_llama_generate returned $code (see DAZZLE_LLAMA_E_* constants)")
}
