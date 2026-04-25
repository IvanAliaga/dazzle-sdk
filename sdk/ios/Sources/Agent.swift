// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Observable, UI-friendly orchestrator around an `LLMClient`, a set of
/// `Tool`s and a `ContextStore` of chat turns.
///
/// Designed to bind directly to SwiftUI via `@Observable`:
///
/// ```swift
/// struct ChatScreen: View {
///     @Bindable var agent: ChatAgentImpl
///     @State private var input = ""
///     var body: some View {
///         VStack {
///             List(agent.messages) { MessageBubble($0) }
///             if let s = agent.streaming { TypingBubble(s.text) }
///             HStack {
///                 TextField("Message", text: $input)
///                 Button("Send") { agent.send(input); input = "" }
///                     .disabled(agent.status != .idle)
///             }
///         }
///     }
/// }
/// ```
@MainActor
public protocol Agent: AnyObject {
    /// Identifier of the conversation thread. Two agents built with the
    /// same `threadId` against the same Dazzle namespace share memory.
    var threadId: String { get }

    /// Committed chat history, oldest first.
    var messages: [ChatTurn] { get }

    /// The assistant message currently being streamed; nil when idle.
    var streaming: StreamingMessage? { get }

    /// Coarse-grained lifecycle state.
    var status: AgentStatus { get }

    /// The tool set exposed to the LLM. Mutable at runtime.
    var tools: [any ErasedTool] { get set }

    /// Fire-and-forget user input. No-op when status != .idle.
    func send(_ input: String)

    /// Hard cancel — aborts an in-flight turn.
    func cancel()

    /// Run the configured `CompactionPolicy` synchronously.
    func compact() async

    /// Stop the turn loop, close the LLMClient, close memory.
    func close()
}

/// One persisted turn of a conversation.
public struct ChatTurn: Sendable, Identifiable, Equatable {
    public let id: String
    public let role: Role
    public let text: String
    public let toolCalls: [ToolCall]
    public let toolCallId: String?
    public let timestamp: Int64

    public init(
        id: String,
        role: Role,
        text: String,
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.timestamp = timestamp
    }

    /// Convert to a prompt Message.
    public func toMessage() -> Message {
        Message(role: role, content: text, toolCalls: toolCalls, toolCallId: toolCallId)
    }
}

/// In-flight assistant message. `text` accumulates token deltas.
public struct StreamingMessage: Sendable, Equatable {
    public var text: String
    public var activeTool: String?

    public init(text: String = "", activeTool: String? = nil) {
        self.text = text
        self.activeTool = activeTool
    }
}

/// Coarse lifecycle state for the Agent.
public enum AgentStatus: Sendable, Equatable {
    case idle
    case thinking
    case toolCalling
    case streaming
    case error
}
