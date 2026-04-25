// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import kotlinx.coroutines.flow.StateFlow

/**
 * Observable, UI-friendly orchestrator around an [LLMClient], a set of
 * [Tool]s and a [ContextStore] of chat turns.
 *
 * Designed to bind directly to Compose / SwiftUI state:
 *
 * ```kotlin
 * @Composable
 * fun ChatScreen(agent: Agent) {
 *     val messages  by agent.messages.collectAsState()
 *     val streaming by agent.streaming.collectAsState()
 *     val status    by agent.status.collectAsState()
 *     var input by remember { mutableStateOf("") }
 *
 *     Column {
 *         LazyColumn(Modifier.weight(1f)) {
 *             items(messages, key = { it.id }) { MessageBubble(it) }
 *             streaming?.let { item { TypingBubble(it.text, tool = it.activeTool) } }
 *         }
 *         Row {
 *             TextField(value = input, onValueChange = { input = it })
 *             Button(
 *                 enabled = status == AgentStatus.Idle,
 *                 onClick = { agent.send(input); input = "" },
 *             ) { Text("Send") }
 *         }
 *     }
 * }
 * ```
 *
 * Nothing in the UI layer touches the underlying [LLMClient] or the
 * [Tool] invocation loop — the Agent handles that internally and only
 * exposes the three StateFlows.
 */
interface Agent : AutoCloseable {

    /** Identifier of the conversation thread. Enables resumption: two
     *  agents built with the same [threadId] against the same Dazzle
     *  namespace share memory. */
    val threadId: String

    /** Committed chat history, oldest first. Updated after each full
     *  turn (user → assistant final text). */
    val messages: StateFlow<List<ChatTurn>>

    /** The assistant message currently being streamed. `null` when idle.
     *  Updated token-by-token so UIs can show a "typing" bubble. */
    val streaming: StateFlow<StreamingMessage?>

    /** Coarse-grained lifecycle state for disabling the send button,
     *  showing spinners, etc. */
    val status: StateFlow<AgentStatus>

    /** The tool set this agent exposes to the LLM. Mutable at runtime —
     *  appending a new tool takes effect on the next `send()`. */
    val tools: MutableList<Tool<*, *>>

    /** Fire-and-forget input — appends the user turn and starts the
     *  agent's turn loop in the background. No-op if [status] is not
     *  [AgentStatus.Idle]. */
    fun send(input: String)

    /** Hard cancel — aborts an in-flight turn if any, sets status to
     *  [AgentStatus.Idle]. The last partial streaming message is
     *  discarded (NOT committed to [messages]). */
    fun cancel()

    /** Run the configured [CompactionPolicy] synchronously. Safe to call
     *  at any time; the agent's own turn loop triggers this automatically
     *  per the policy's schedule. */
    suspend fun compact()

    /** Stop the turn loop (if running), close the LLMClient, close the
     *  memory store. Idempotent. */
    override fun close()
}

/**
 * One persisted turn of a conversation.
 *
 * IDs are stable across restarts — the [ContextStore] re-reads them by
 * [id] on resumption. Roles and tool-call metadata mirror the [Message]
 * wire format exactly for seamless prompt round-tripping.
 */
data class ChatTurn(
    val id: String,
    val role: Role,
    val text: String,
    val toolCalls: List<ToolCall> = emptyList(),
    val toolCallId: String? = null,
    val timestamp: Long = System.currentTimeMillis(),
) {
    /** Convert to a prompt [Message]. */
    fun toMessage(): Message = Message(
        role = role,
        content = text,
        toolCalls = toolCalls,
        toolCallId = toolCallId,
    )
}

/**
 * In-flight assistant message. [text] accumulates token deltas; when a
 * tool is being invoked [activeTool] names it so the UI can show the
 * right affordance.
 */
data class StreamingMessage(
    val text: String = "",
    val activeTool: String? = null,
)

/**
 * Coarse lifecycle state for the Agent. Fine-grained progress (token
 * counts, retry attempts, etc.) stays out of scope — UIs that want that
 * level of detail can wire the SDK's telemetry hooks (Layer 3).
 */
enum class AgentStatus {
    /** Ready to accept a new user turn. */
    Idle,

    /** Assembling the prompt, calling the LLM (text generation pending). */
    Thinking,

    /** Model produced tool_calls; one or more [Tool]s are executing. */
    ToolCalling,

    /** Text is streaming from the model into [Agent.streaming]. */
    Streaming,

    /** Last turn ended in error. See [Agent.lastError] for the exception. */
    Error,
}
