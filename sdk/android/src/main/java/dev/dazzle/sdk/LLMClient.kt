// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import kotlinx.coroutines.flow.Flow

/**
 * Abstract LLM client that an [Agent] drives.
 *
 * The SDK does not bundle an LLM runtime — the dev plugs in whichever
 * engine fits their deployment:
 *
 *   - **LiteRT-LM** (on-device, Gemma / Llama / Qwen) — via a small adapter
 *   - **llama.cpp** wrapper — same adapter pattern
 *   - **OpenAI / Anthropic / Gemini HTTP API** — for cloud-augmented apps
 *   - **[FakeLLMClient]** — for unit tests without loading a real model
 *
 * The Layer 3 `DazzleEdge` bundle will ship a wired-up LiteRT-LM adapter
 * for the common case so 80% of consumers never write this adapter.
 *
 * ## Contract
 *
 * - [complete] is the one-shot path — returns the full response as a
 *   [Completion]. Use for short, non-streaming flows.
 * - [stream] is the incremental path — emits [Delta] events as the model
 *   produces tokens. Use for UIs that show text token-by-token.
 *
 * Both methods respect the caller's cancellation: when the calling
 * coroutine is cancelled, the adapter should stop the underlying
 * inference promptly (`litertlm_cancel`, `AbortController`, etc.).
 */
interface LLMClient : AutoCloseable {

    /** Descriptive label for logs / telemetry. Does not need to be unique. */
    val modelId: String

    /**
     * Submit the conversation history and return the model's full response.
     *
     * If [tools] is non-empty the model MAY respond with tool_calls; the
     * caller is expected to execute those and re-invoke [complete] with
     * the tool results appended as `Role.tool` messages.
     *
     * @throws DazzleException.ContextOverflow when [messages] exceeds the
     *         model's context window and no truncation was applied upstream
     * @throws DazzleException.ModelLoadFailed if the model isn't ready yet
     */
    suspend fun complete(
        messages: List<Message>,
        tools: List<ToolDeclaration> = emptyList(),
    ): Completion

    /**
     * Same as [complete] but streams [Delta] events as the model emits them.
     *
     * The resulting Flow is cold — each collection triggers a fresh
     * inference. Cancel the collecting coroutine to abort mid-stream.
     */
    fun stream(
        messages: List<Message>,
        tools: List<ToolDeclaration> = emptyList(),
    ): Flow<Delta>

    /** Release any native resources (model weights, KV cache). Safe to
     *  call multiple times. The SDK automatically calls this on [Agent.close]. */
    override fun close()
}
