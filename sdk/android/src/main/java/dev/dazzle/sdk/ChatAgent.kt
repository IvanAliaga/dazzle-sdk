// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * Default [Agent] implementation — a chat orchestrator.
 *
 * Owns:
 *   - A [ContextStore]<[ChatTurn]> for persistent memory (survives
 *     process restart when you resume with the same `threadId`)
 *   - An [LLMClient] for inference
 *   - A list of [Tool]s for function calling
 *   - A [ContextWindow] and [CompactionPolicy]
 *
 * Builds the standard tool-call loop:
 *
 *   1. Append user turn → memory
 *   2. Assemble prompt = systemPrompt + window(memory)
 *   3. `llm.stream(prompt, tools)` → consume [Delta] stream
 *   4. If final emit has [ToolCall]s, invoke each → append tool
 *      responses → go back to step 3
 *   5. Commit assistant turn with final text → memory
 *   6. Run compaction if the policy fires
 *
 * Exposes the progress via StateFlows so a Compose / SwiftUI surface
 * binds without any glue code.
 */
class ChatAgentImpl internal constructor(
    override val threadId: String,
    private val memory: ContextStore<ChatTurn>,
    private val llm: LLMClient,
    override val tools: MutableList<Tool<*, *>>,
    private val systemPromptTemplate: String,
    private val systemPromptVars: () -> Map<String, String>,
    private val contextWindow: ContextWindow,
    private val compaction: CompactionPolicy,
    private val execution: ExecutionPolicy,
    private val maxToolIterations: Int,
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
) : Agent {

    private val _messages = MutableStateFlow<List<ChatTurn>>(emptyList())
    override val messages: StateFlow<List<ChatTurn>> = _messages.asStateFlow()

    private val _streaming = MutableStateFlow<StreamingMessage?>(null)
    override val streaming: StateFlow<StreamingMessage?> = _streaming.asStateFlow()

    private val _status = MutableStateFlow(AgentStatus.Idle)
    override val status: StateFlow<AgentStatus> = _status.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + execution.dispatcher)
    private val sendMutex = Mutex()
    private var currentJob: Job? = null
    private var turnsSinceCompaction = 0

    init {
        // Warm up from persistent memory.
        _messages.value = memory.iterate().toList()
            .sortedBy { it.second.timestamp }
            .map { it.second }
    }

    override fun send(input: String) {
        if (_status.value != AgentStatus.Idle) return

        _status.value = AgentStatus.Thinking
        currentJob = scope.launch {
            try {
                sendMutex.withLock { runTurn(input) }
            } catch (t: Throwable) {
                _status.value = AgentStatus.Error
                throw t
            } finally {
                _streaming.value = null
                if (_status.value != AgentStatus.Error) _status.value = AgentStatus.Idle
            }
        }
    }

    override fun cancel() {
        currentJob?.cancel()
        _streaming.value = null
        _status.value = AgentStatus.Idle
    }

    override suspend fun compact() {
        runCompaction(force = true)
    }

    override fun close() {
        scope.cancel()
        memory.close()
        llm.close()
    }

    // ── Internal: single turn execution ──────────────────────────────────

    private suspend fun runTurn(userInput: String) {
        // 1. Append user turn
        val userTurn = ChatTurn(
            id = idFactory(),
            role = Role.user,
            text = userInput,
            timestamp = System.currentTimeMillis(),
        )
        memory.put(userTurn.id, userTurn)
        _messages.update { it + userTurn }

        var iteration = 0
        var finalAssistant: ChatTurn? = null

        while (iteration < maxToolIterations) {
            iteration++

            // 2. Build prompt
            val history = assembleHistory(userInput)
            val prompt = buildList {
                add(Message(Role.system, renderSystemPrompt()))
                addAll(history.map { it.toMessage() })
            }
            val toolDecls = tools.map { it.toDeclaration() }

            // 3. Stream LLM response
            _status.value = AgentStatus.Streaming
            _streaming.value = StreamingMessage()
            val collected = collectStream(prompt, toolDecls)

            // 4. Commit either a tool-calling assistant turn or a final text
            if (collected.toolCalls.isNotEmpty()) {
                val assistantTurn = ChatTurn(
                    id = idFactory(),
                    role = Role.assistant,
                    text = collected.text,   // may be empty when model only calls tools
                    toolCalls = collected.toolCalls,
                    timestamp = System.currentTimeMillis(),
                )
                memory.put(assistantTurn.id, assistantTurn)
                _messages.update { it + assistantTurn }

                // Execute each tool call, append response turn
                _status.value = AgentStatus.ToolCalling
                for (call in collected.toolCalls) {
                    val responseText = runToolCall(call)
                    val toolTurn = ChatTurn(
                        id = idFactory(),
                        role = Role.tool,
                        text = responseText,
                        toolCallId = call.id,
                        timestamp = System.currentTimeMillis(),
                    )
                    memory.put(toolTurn.id, toolTurn)
                    _messages.update { it + toolTurn }
                }
                _status.value = AgentStatus.Thinking
                // loop back to re-prompt with tool results appended
            } else {
                // Pure text response — this is the terminal state for this turn.
                finalAssistant = ChatTurn(
                    id = idFactory(),
                    role = Role.assistant,
                    text = collected.text,
                    timestamp = System.currentTimeMillis(),
                )
                memory.put(finalAssistant.id, finalAssistant)
                _messages.update { it + finalAssistant }
                break
            }
        }

        // Ran out of iterations without a final text — inject an error turn
        // so the UI still sees a terminal message.
        if (finalAssistant == null) {
            val giveUp = ChatTurn(
                id = idFactory(),
                role = Role.assistant,
                text = "(agent stopped after $maxToolIterations tool iterations)",
                timestamp = System.currentTimeMillis(),
            )
            memory.put(giveUp.id, giveUp)
            _messages.update { it + giveUp }
        }

        // Compaction check — advance counter, run if the policy fires.
        turnsSinceCompaction++
        runCompaction(force = false)
    }

    /** Drains an LLM stream into a single [StreamedTurn], updating
     *  [_streaming] with each text chunk so the UI renders incrementally. */
    private suspend fun collectStream(
        prompt: List<Message>,
        toolDecls: List<ToolDeclaration>,
    ): StreamedTurn {
        val textBuffer = StringBuilder()
        // tool_call id → accumulator (name known at start, args built up)
        val toolCallBuilders = linkedMapOf<String, ToolCallBuilder>()
        var activeToolName: String? = null

        llm.stream(prompt, toolDecls).collect { delta ->
            when (delta) {
                is Delta.Text -> {
                    textBuffer.append(delta.chunk)
                    _streaming.value = _streaming.value?.copy(text = textBuffer.toString())
                        ?: StreamingMessage(text = textBuffer.toString())
                }
                is Delta.ToolCallStart -> {
                    toolCallBuilders[delta.id] = ToolCallBuilder(name = delta.name)
                    activeToolName = delta.name
                    _streaming.value = _streaming.value?.copy(activeTool = delta.name)
                        ?: StreamingMessage(activeTool = delta.name)
                }
                is Delta.ToolCallArgs -> {
                    toolCallBuilders[delta.id]?.args?.append(delta.argsChunk)
                }
                Delta.End -> { /* loop exits naturally */ }
            }
        }

        return StreamedTurn(
            text = textBuffer.toString(),
            toolCalls = toolCallBuilders.map { (id, b) ->
                ToolCall(id = id, name = b.name, arguments = b.args.toString())
            },
        )
    }

    /** Look up the Tool by name, parse args, invoke, encode response.
     *  Surfaces errors as tool responses so the LLM can self-correct. */
    @Suppress("UNCHECKED_CAST")
    private suspend fun runToolCall(call: ToolCall): String {
        val tool = tools.firstOrNull { it.name == call.name } as? Tool<Any?, Any?>
            ?: return errorPayload("UnknownTool", "Tool '${call.name}' not registered")

        return try {
            val args = tool.argsFromJson(call.arguments)
            val ctx = ToolContext(
                execution = execution,
                stores = mapOf("memory" to memory),
            )
            val result = tool.invoke(args, ctx)
            tool.returnToJson(result)
        } catch (t: Throwable) {
            errorPayload(t::class.simpleName ?: "Error", t.message ?: "")
        }
    }

    /** Build the in-call history per the [ContextWindow] policy. */
    private fun assembleHistory(@Suppress("UNUSED_PARAMETER") userInput: String): List<ChatTurn> {
        val all = _messages.value
        return when (val cw = contextWindow) {
            is ContextWindow.LastN -> all.takeLast(cw.n)
            ContextWindow.All -> all
            is ContextWindow.VectorRecall -> {
                // Recent slice + semantic top-k from store
                val recent = all.takeLast(cw.keepRecent)
                val recentIds = recent.map { it.id }.toSet()
                val vector = cw.embedder(userInput)
                val semantic = cw.store.semanticSearch(vector, k = cw.k)
                    .map { it.value }
                    .filter { it.id !in recentIds }
                (semantic + recent).distinctBy { it.id }
            }
        }
    }

    private fun renderSystemPrompt(): String {
        val vars = systemPromptVars()
        if (vars.isEmpty()) return systemPromptTemplate
        var out = systemPromptTemplate
        for ((k, v) in vars) out = out.replace("{$k}", v)
        return out
    }

    private suspend fun runCompaction(force: Boolean) {
        when (val p = compaction) {
            CompactionPolicy.None -> return
            is CompactionPolicy.MaxTurns -> {
                if (!force && _messages.value.size <= p.maxTurns) return
                val toDrop = _messages.value.size - p.maxTurns
                if (toDrop > 0) {
                    val drop = _messages.value.take(toDrop)
                    for (t in drop) memory.delete(t.id)
                    _messages.update { it.drop(toDrop) }
                }
            }
            is CompactionPolicy.TimeRetention -> {
                val cutoff = System.currentTimeMillis() - p.retention.inWholeMilliseconds
                val keep = _messages.value.filter { it.timestamp >= cutoff }
                val drop = _messages.value - keep.toSet()
                for (t in drop) memory.delete(t.id)
                _messages.value = keep
            }
            is CompactionPolicy.RollingSummary -> {
                if (!force && turnsSinceCompaction < p.everyNTurns) return
                turnsSinceCompaction = 0
                val all = _messages.value
                val keep = all.takeLast(p.keepRecent)
                val oldBlock = all.dropLast(p.keepRecent)
                if (oldBlock.isEmpty()) return
                val summaryText = p.summarizer(oldBlock)
                // Delete originals, prepend one summary turn
                for (t in oldBlock) memory.delete(t.id)
                val summary = ChatTurn(
                    id = idFactory(),
                    role = Role.assistant,
                    text = "[SUMMARY of ${oldBlock.size} earlier turns]\n$summaryText",
                    timestamp = oldBlock.first().timestamp,
                )
                memory.put(summary.id, summary)
                _messages.value = listOf(summary) + keep
            }
            is CompactionPolicy.Custom -> {
                p.fn(memory)
                // Re-read memory since the custom fn may have rewritten anything.
                _messages.value = memory.iterate().toList()
                    .sortedBy { it.second.timestamp }
                    .map { it.second }
            }
        }
    }

    private fun errorPayload(code: String, message: String): String =
        """{"error":"$code","message":"${message.replace("\"", "\\\"")}"}"""

    // ── Internal helpers ──────────────────────────────────────────────────

    private data class StreamedTurn(val text: String, val toolCalls: List<ToolCall>)
    private data class ToolCallBuilder(val name: String, val args: StringBuilder = StringBuilder())
}

// ── Public builder for ChatAgent ─────────────────────────────────────────

/**
 * Build a [ChatAgentImpl] with sensible defaults.
 *
 * Minimum viable usage:
 *
 * ```kotlin
 * val agent = dazzle.chatAgent(
 *     threadId = "session:42",
 *     llm = myLLMClient,
 * )
 * agent.send("Hello!")
 * ```
 *
 * Full customization:
 *
 * ```kotlin
 * val agent = dazzle.chatAgent(
 *     threadId = "session:42",
 *     llm = myLLMClient,
 * ) {
 *     systemPrompt = "You are a helpful edge assistant. Today is {date}."
 *     systemPromptVars { mapOf("date" to LocalDate.now().toString()) }
 *     tools += weatherTool
 *     tools += chatMemory.asSemanticSearchTool(...)
 *     contextWindow  = ContextWindow.LastN(n = 30)
 *     compaction     = CompactionPolicy.MaxTurns(maxTurns = 500)
 *     execution      = ExecutionPolicy.balanced
 *     maxToolIterations = 10
 * }
 * ```
 */
class ChatAgentBuilder internal constructor(
    private val dazzle: Dazzle,
    internal val threadId: String,
    internal val llm: LLMClient,
) {
    var systemPrompt: String = "You are a helpful assistant."
    private var varsFactory: () -> Map<String, String> = { emptyMap() }
    val tools: MutableList<Tool<*, *>> = mutableListOf()
    var contextWindow: ContextWindow = ContextWindow.default
    var compaction: CompactionPolicy = CompactionPolicy.default
    var execution: ExecutionPolicy = ExecutionPolicy.balanced
    var maxToolIterations: Int = 8

    /** Hook for dynamic template substitutions — re-evaluated per turn. */
    fun systemPromptVars(fn: () -> Map<String, String>) { varsFactory = fn }

    internal fun build(): ChatAgentImpl {
        val memory = dazzle.contextStore<ChatTurn>("agent:$threadId:memory") {
            encode { t -> buildMap {
                put("role", t.role.name)
                put("text", t.text)
                put("ts",   t.timestamp.toString())
                t.toolCallId?.let { put("toolCallId", it) }
                if (t.toolCalls.isNotEmpty()) put("toolCalls", encodeToolCalls(t.toolCalls))
            } }
            decode { f -> ChatTurn(
                id = f["id"] ?: "unknown",
                role = f["role"]?.let(::roleFromString) ?: Role.user,
                text = f["text"].orEmpty(),
                toolCalls = f["toolCalls"]?.let(::decodeToolCalls) ?: emptyList(),
                toolCallId = f["toolCallId"],
                timestamp = f["ts"]?.toLongOrNull() ?: 0L,
            ) }
            timeRange { it.timestamp }
            tags { setOf("role:${it.role.name}") }
        }
        return ChatAgentImpl(
            threadId = threadId,
            memory = memory,
            llm = llm,
            tools = tools,
            systemPromptTemplate = systemPrompt,
            systemPromptVars = varsFactory,
            contextWindow = contextWindow,
            compaction = compaction,
            execution = execution,
            maxToolIterations = maxToolIterations,
        )
    }
}

/** Factory entry point on [Dazzle]. */
fun Dazzle.chatAgent(
    threadId: String,
    llm: LLMClient,
    build: ChatAgentBuilder.() -> Unit = {},
): Agent = ChatAgentBuilder(this, threadId, llm).apply(build).build()

// ── Small helpers for ChatTurn serialization ────────────────────────────

private fun roleFromString(s: String): Role = try { Role.valueOf(s) } catch (_: Throwable) { Role.user }

private fun encodeToolCalls(calls: List<ToolCall>): String = buildString {
    append('[')
    calls.forEachIndexed { i, c ->
        if (i > 0) append('|')
        append(c.id); append('~'); append(c.name); append('~'); append(c.arguments.replace("|", "\\|"))
    }
    append(']')
}

private fun decodeToolCalls(raw: String): List<ToolCall> {
    if (raw.length < 2 || raw.first() != '[' || raw.last() != ']') return emptyList()
    val body = raw.substring(1, raw.length - 1)
    if (body.isEmpty()) return emptyList()
    return body.split('|').mapNotNull { chunk ->
        val parts = chunk.split('~', limit = 3)
        if (parts.size == 3) ToolCall(parts[0], parts[1], parts[2].replace("\\|", "|")) else null
    }
}
