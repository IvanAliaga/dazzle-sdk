// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.delay

/**
 * In-memory scripted [LLMClient] for unit tests.
 *
 * Returns the next entry from a fixed [Script] each time [complete] or
 * [stream] is called. The dev writes the exact sequence of assistant
 * replies (text or tool_calls) they expect the agent to produce, and
 * the agent's tool-call loop runs against that script without loading
 * a real model.
 *
 * ```kotlin
 * val llm = FakeLLMClient(
 *     modelId = "fake:test",
 *     script = listOf(
 *         // 1st turn: model asks to call the weather tool
 *         Completion.ToolCalls(Message(
 *             role = Role.assistant, content = "",
 *             toolCalls = listOf(ToolCall("c1", "weather.get", """{"city":"Lima"}""")),
 *         )),
 *         // 2nd turn (after tool result): model produces final text
 *         Completion.Text(Message(Role.assistant, "It's 22 °C in Lima.")),
 *     ),
 * )
 * ```
 *
 * ## Streaming
 *
 * [stream] emits the same [Completion] decomposed into [Delta]s:
 *   - Text completions split into 1+ [Delta.Text] chunks of [streamChunkSize]
 *     characters (simulates token-by-token streaming)
 *   - ToolCalls emit [Delta.ToolCallStart] + [Delta.ToolCallArgs] fragments
 *   - Always terminated with [Delta.End]
 */
class FakeLLMClient(
    override val modelId: String = "fake:test",
    private val script: List<Completion>,
    /** Number of characters per simulated streaming chunk. */
    private val streamChunkSize: Int = 8,
    /** Delay between streamed chunks, to mimic real-time streaming in UI tests. */
    private val chunkDelayMs: Long = 0,
) : LLMClient {

    private var cursor = 0

    /** Number of times [complete] / [stream] have been invoked so far. */
    val callCount: Int get() = cursor

    /**
     * Every call the agent made to the LLM so far — useful for asserting
     * "the LLM saw this history" in tests.
     */
    private val _observedHistories = mutableListOf<List<Message>>()
    val observedHistories: List<List<Message>> get() = _observedHistories.toList()

    override suspend fun complete(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Completion {
        _observedHistories.add(messages)
        require(cursor < script.size) {
            "FakeLLMClient script exhausted after $cursor calls — expected ${script.size} entries"
        }
        return script[cursor++]
    }

    override fun stream(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Flow<Delta> = flow {
        _observedHistories.add(messages)
        require(cursor < script.size) {
            "FakeLLMClient script exhausted after $cursor calls — expected ${script.size} entries"
        }
        val next = script[cursor++]
        when (next) {
            is Completion.Text -> {
                val text = next.message.content
                var i = 0
                while (i < text.length) {
                    val chunk = text.substring(i, (i + streamChunkSize).coerceAtMost(text.length))
                    emit(Delta.Text(chunk))
                    if (chunkDelayMs > 0) delay(chunkDelayMs)
                    i += streamChunkSize
                }
            }
            is Completion.ToolCalls -> {
                for (tc in next.message.toolCalls) {
                    emit(Delta.ToolCallStart(id = tc.id, name = tc.name))
                    // Split arguments into fragments like real streaming APIs do
                    var i = 0
                    val args = tc.arguments
                    while (i < args.length) {
                        val chunk = args.substring(i, (i + streamChunkSize).coerceAtMost(args.length))
                        emit(Delta.ToolCallArgs(id = tc.id, argsChunk = chunk))
                        if (chunkDelayMs > 0) delay(chunkDelayMs)
                        i += streamChunkSize
                    }
                }
            }
        }
        emit(Delta.End)
    }

    override fun close() {
        // No resources to release for the fake.
    }
}
