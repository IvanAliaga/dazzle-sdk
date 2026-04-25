// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// One turn of a conversation with an LLM. Shape mirrors the OpenAI /
/// Anthropic / Gemini function-calling APIs so prompts port line-by-line.
public struct Message: Sendable, Equatable {
    public let role: Role
    public let content: String
    /// Tool invocations the model wants the caller to execute.
    /// Populated only on `role == .assistant` turns.
    public let toolCalls: [ToolCall]
    /// Links a `role == .tool` response to the assistant turn that
    /// originally requested the call (matches a `ToolCall.id`).
    public let toolCallId: String?

    public init(
        role: Role,
        content: String,
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

/// Conversation participant — lowercase raw values to match the wire
/// formats used by OpenAI / Anthropic / Gemini / Ollama / vLLM.
public enum Role: String, Sendable, Equatable {
    case system, user, assistant, tool
}

/// A single tool invocation request from the model.
/// `arguments` is a **JSON object as a raw string** (not pre-parsed)
/// to match the OpenAI wire format exactly.
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Final reply from `LLMClient.complete`.
public enum Completion: Sendable, Equatable {
    /// The model produced free-text output.
    case text(Message)
    /// The model wants the caller to run one or more tools. After
    /// executing them, append the results as `role == .tool` messages
    /// and re-invoke `complete` with the extended history.
    case toolCalls(Message)
}

/// Incremental event from `LLMClient.stream`. A single response
/// decomposes into zero or more `.text` / `.toolCallStart` /
/// `.toolCallArgs` events followed by one `.end`.
public enum Delta: Sendable, Equatable {
    case text(String)
    case toolCallStart(id: String, name: String)
    case toolCallArgs(id: String, chunk: String)
    case end
}
