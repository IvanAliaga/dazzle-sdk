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

package dev.dazzle.sdk

/**
 * One turn of a conversation with an LLM.
 *
 * Shape is deliberately identical to OpenAI / Anthropic / Gemini function-
 * calling APIs so prompts written for those services port line-by-line:
 *
 * | Field         | OpenAI | Anthropic | Gemini |
 * |---------------|--------|-----------|--------|
 * | role          | ✓      | ✓         | ✓      |
 * | content       | ✓      | ✓ (text)  | ✓      |
 * | tool_calls    | ✓      | ✓         | ✓      |
 * | tool_call_id  | ✓      | ✓         | ✓      |
 *
 * ## Building a conversation
 *
 * ```kotlin
 * val history = listOf(
 *     Message(Role.system,    content = "You are a helpful edge assistant."),
 *     Message(Role.user,      content = "What's the weather in Lima?"),
 *     Message(Role.assistant, content = "", toolCalls = listOf(
 *         ToolCall(id = "call_1", name = "weather.get", arguments = """{"city":"Lima"}""")
 *     )),
 *     Message(Role.tool,      content = "{\"temp\":22,\"condition\":\"cloudy\"}",
 *             toolCallId = "call_1"),
 *     Message(Role.assistant, content = "It's 22 °C and cloudy."),
 * )
 * ```
 */
data class Message(
    val role: Role,
    val content: String,
    /** Tool invocations the model wants the caller to execute. Populated
     *  only on `role = assistant` turns. */
    val toolCalls: List<ToolCall> = emptyList(),
    /** Links a `role = tool` response to the assistant turn that
     *  originally requested the call (matches a [ToolCall.id]). */
    val toolCallId: String? = null,
)

/**
 * Conversation participant, lowercase to match the wire formats used by
 * OpenAI / Anthropic / Gemini / Ollama / vLLM / llama.cpp.
 */
@Suppress("EnumEntryName")
enum class Role { system, user, assistant, tool }

/**
 * A single tool invocation request from the model.
 *
 * [arguments] is a **JSON object as a raw string** (not pre-parsed) to
 * match the OpenAI wire format exactly. The caller validates and parses
 * it against the corresponding tool's schema before invocation.
 */
data class ToolCall(
    val id: String,
    val name: String,
    val arguments: String,
)

/** Final reply from [LLMClient.complete]. */
sealed class Completion {
    /** The model produced free-text output. */
    data class Text(val message: Message) : Completion()

    /** The model wants the caller to run one or more tools. [message]
     *  carries `toolCalls` and an empty `content`. After executing the
     *  tools, append the results as `Role.tool` messages and re-invoke
     *  [LLMClient.complete] with the extended history. */
    data class ToolCalls(val message: Message) : Completion()
}

/**
 * Incremental event from [LLMClient.stream]. A single [complete] response
 * decomposes into zero or more [Text] / [ToolCallStart] / [ToolCallArgs]
 * events followed by one [End].
 */
sealed class Delta {
    /** Next text fragment from the assistant. */
    data class Text(val chunk: String) : Delta()

    /** A tool call is starting. More [ToolCallArgs] deltas with the same
     *  [id] will follow, each carrying a piece of the JSON arguments. */
    data class ToolCallStart(val id: String, val name: String) : Delta()

    /** A fragment of a tool call's `arguments` JSON. Concatenate all
     *  fragments sharing the same [id] to get the full argument string. */
    data class ToolCallArgs(val id: String, val argsChunk: String) : Delta()

    /** End of stream. The caller has received everything the model emitted. */
    data object End : Delta()
}
