// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Default `Agent` implementation — a chat orchestrator.
///
/// Owns a `ContextStore<ChatTurn>` for persistent memory, an `LLMClient`
/// for inference, a list of `Tool`s for function calling, plus a
/// `ContextWindow` and `CompactionPolicy`. Runs the standard tool-call
/// loop and exposes observable progress via `@Observable` for SwiftUI.
@MainActor
@Observable
public final class ChatAgentImpl: Agent {

    public let threadId: String

    public private(set) var messages: [ChatTurn] = []
    public private(set) var streaming: StreamingMessage? = nil
    public private(set) var status: AgentStatus = .idle

    public var tools: [any ErasedTool]

    private let memory: DazzleContextStore<ChatTurn>
    private let llm: any LLMClient
    private let systemPromptTemplate: String
    private let systemPromptVars: @Sendable () -> [String: String]
    private let contextWindow: ContextWindow
    private let compaction: CompactionPolicy
    private let execution: ExecutionPolicy
    private let maxToolIterations: Int
    private var turnsSinceCompaction = 0

    private var currentTask: Task<Void, Never>? = nil

    internal init(
        threadId: String,
        memory: DazzleContextStore<ChatTurn>,
        llm: any LLMClient,
        tools: [any ErasedTool],
        systemPromptTemplate: String,
        systemPromptVars: @escaping @Sendable () -> [String: String],
        contextWindow: ContextWindow,
        compaction: CompactionPolicy,
        execution: ExecutionPolicy,
        maxToolIterations: Int
    ) {
        self.threadId = threadId
        self.memory = memory
        self.llm = llm
        self.tools = tools
        self.systemPromptTemplate = systemPromptTemplate
        self.systemPromptVars = systemPromptVars
        self.contextWindow = contextWindow
        self.compaction = compaction
        self.execution = execution
        self.maxToolIterations = maxToolIterations

        // Warm up from persistent memory.
        var restored: [ChatTurn] = []
        let it = memory.iterate()
        while let (_, v) = it.next() { restored.append(v) }
        restored.sort { $0.timestamp < $1.timestamp }
        self.messages = restored
    }

    public func send(_ input: String) {
        guard status == .idle else { return }
        status = .thinking
        currentTask = Task { @MainActor in
            defer {
                self.streaming = nil
                if self.status != .error { self.status = .idle }
            }
            do {
                try await self.runTurn(input)
            } catch {
                self.status = .error
            }
        }
    }

    public func cancel() {
        currentTask?.cancel()
        streaming = nil
        status = .idle
    }

    public func compact() async {
        await runCompaction(force: true)
    }

    public func close() {
        currentTask?.cancel()
        memory.close()
        llm.close()
    }

    // ── Internal: single turn execution ─────────────────────────────────

    private func runTurn(_ userInput: String) async throws {
        let userTurn = ChatTurn(id: UUID().uuidString, role: .user, text: userInput)
        try memory.put(id: userTurn.id, value: userTurn)
        messages.append(userTurn)

        var iteration = 0
        var final: ChatTurn? = nil

        while iteration < maxToolIterations && !Task.isCancelled {
            iteration += 1
            let history = assembleHistory(userInput: userInput)
            var prompt: [Message] = [Message(role: .system, content: renderSystemPrompt())]
            prompt.append(contentsOf: history.map { $0.toMessage() })
            let toolDecls = tools.map { $0.toDeclaration() }

            status = .streaming
            streaming = StreamingMessage()

            let collected = try await collectStream(prompt: prompt, toolDecls: toolDecls)

            if !collected.toolCalls.isEmpty {
                let assistantTurn = ChatTurn(
                    id: UUID().uuidString,
                    role: .assistant,
                    text: collected.text,
                    toolCalls: collected.toolCalls
                )
                try memory.put(id: assistantTurn.id, value: assistantTurn)
                messages.append(assistantTurn)

                status = .toolCalling
                for call in collected.toolCalls {
                    let responseText = await runToolCall(call)
                    let toolTurn = ChatTurn(
                        id: UUID().uuidString,
                        role: .tool,
                        text: responseText,
                        toolCallId: call.id
                    )
                    try memory.put(id: toolTurn.id, value: toolTurn)
                    messages.append(toolTurn)
                }
                status = .thinking
            } else {
                final = ChatTurn(id: UUID().uuidString, role: .assistant, text: collected.text)
                try memory.put(id: final!.id, value: final!)
                messages.append(final!)
                break
            }
        }

        if final == nil && !Task.isCancelled {
            let giveUp = ChatTurn(
                id: UUID().uuidString, role: .assistant,
                text: "(agent stopped after \(maxToolIterations) tool iterations)"
            )
            try memory.put(id: giveUp.id, value: giveUp)
            messages.append(giveUp)
        }

        turnsSinceCompaction += 1
        await runCompaction(force: false)
    }

    private func collectStream(prompt: [Message], toolDecls: [ToolDeclaration]) async throws -> StreamedTurn {
        var text = ""
        var callBuilders: [String: (name: String, args: String)] = [:]
        var callOrder: [String] = []

        for try await delta in llm.stream(messages: prompt, tools: toolDecls) {
            switch delta {
            case .text(let chunk):
                text += chunk
                streaming = StreamingMessage(text: text, activeTool: streaming?.activeTool)
            case .toolCallStart(let id, let name):
                callBuilders[id] = (name: name, args: "")
                callOrder.append(id)
                streaming = StreamingMessage(text: text, activeTool: name)
            case .toolCallArgs(let id, let chunk):
                if var b = callBuilders[id] {
                    b.args += chunk
                    callBuilders[id] = b
                }
            case .end:
                break
            }
        }

        let calls = callOrder.compactMap { id -> ToolCall? in
            guard let b = callBuilders[id] else { return nil }
            return ToolCall(id: id, name: b.name, arguments: b.args)
        }
        return StreamedTurn(text: text, toolCalls: calls)
    }

    private func runToolCall(_ call: ToolCall) async -> String {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return errorPayload("UnknownTool", "Tool '\(call.name)' not registered")
        }
        do {
            let ctx = ToolContext(execution: execution, stores: ["memory": memory])
            return try await tool.invokeRaw(arguments: call.arguments, ctx: ctx)
        } catch {
            return errorPayload(String(describing: type(of: error)), error.localizedDescription)
        }
    }

    private func assembleHistory(userInput: String) -> [ChatTurn] {
        switch contextWindow {
        case .lastN(let n):
            return Array(messages.suffix(n))
        case .all:
            return messages
        case .vectorRecall(let keepRecent, let k, let store, let embedder):
            let recent = Array(messages.suffix(keepRecent))
            let recentIds = Set(recent.map { $0.id })
            let vec = embedder(userInput)
            let semantic = store.semanticSearch(vector: vec, k: k)
                .map { $0.value }
                .filter { !recentIds.contains($0.id) }
            return Array((semantic + recent).reduce(into: [String: ChatTurn]()) { $0[$1.id] = $1 }.values)
        }
    }

    private func renderSystemPrompt() -> String {
        var out = systemPromptTemplate
        for (k, v) in systemPromptVars() {
            out = out.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return out
    }

    private func runCompaction(force: Bool) async {
        switch compaction {
        case .none:
            return
        case .maxTurns(let maxTurns):
            if !force && messages.count <= maxTurns { return }
            let drop = messages.count - maxTurns
            if drop > 0 {
                let toDrop = Array(messages.prefix(drop))
                for t in toDrop { _ = memory.delete(id: t.id) }
                messages.removeFirst(drop)
            }
        case .timeRetention(let retention):
            let cutoffMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(retention.components.seconds * 1000)
            let keep = messages.filter { $0.timestamp >= cutoffMs }
            let drop = messages.filter { $0.timestamp < cutoffMs }
            for t in drop { _ = memory.delete(id: t.id) }
            messages = keep
        case .rollingSummary(let everyNTurns, let keepRecent, let summarizer):
            if !force && turnsSinceCompaction < everyNTurns { return }
            turnsSinceCompaction = 0
            let keep = Array(messages.suffix(keepRecent))
            let oldBlock = Array(messages.dropLast(keepRecent))
            guard !oldBlock.isEmpty else { return }
            let summaryText = await summarizer(oldBlock)
            for t in oldBlock { _ = memory.delete(id: t.id) }
            let firstTs = oldBlock.first?.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
            let summary = ChatTurn(
                id: UUID().uuidString,
                role: .assistant,
                text: "[SUMMARY of \(oldBlock.count) earlier turns]\n\(summaryText)",
                timestamp: firstTs
            )
            try? memory.put(id: summary.id, value: summary)
            messages = [summary] + keep
        case .custom(let fn):
            await fn(memory)
            var restored: [ChatTurn] = []
            let it = memory.iterate()
            while let (_, v) = it.next() { restored.append(v) }
            restored.sort { $0.timestamp < $1.timestamp }
            messages = restored
        }
    }

    private func errorPayload(_ code: String, _ message: String) -> String {
        "{\"error\":\"\(code)\",\"message\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }

    private struct StreamedTurn {
        let text: String
        let toolCalls: [ToolCall]
    }
}

// ── Public builder for ChatAgent ────────────────────────────────────────

public final class ChatAgentConfig: @unchecked Sendable {
    public var systemPrompt: String = "You are a helpful assistant."
    public var systemPromptVars: @Sendable () -> [String: String] = { [:] }
    public var tools: [any ErasedTool] = []
    public var contextWindow: ContextWindow = .default
    public var compaction: CompactionPolicy = .default
    public var execution: ExecutionPolicy = .balanced
    public var maxToolIterations: Int = 8

    public init() {}
}

public extension Dazzle {
    /// Build a `ChatAgentImpl` with sensible defaults.
    @MainActor
    func chatAgent(
        threadId: String,
        llm: any LLMClient,
        configure: (ChatAgentConfig) -> Void = { _ in }
    ) -> ChatAgentImpl {
        let cfg = ChatAgentConfig()
        configure(cfg)
        let memory = contextStore(
            name: "agent:\(threadId):memory",
            encode: { (t: ChatTurn) -> [String: String] in
                var out: [String: String] = [
                    "role": t.role.rawValue,
                    "text": t.text,
                    "ts":   String(t.timestamp),
                ]
                if let tcId = t.toolCallId { out["toolCallId"] = tcId }
                if !t.toolCalls.isEmpty { out["toolCalls"] = Self.encodeToolCalls(t.toolCalls) }
                return out
            },
            decode: { (f: [String: String]) -> ChatTurn? in
                guard let role = f["role"].flatMap(Role.init(rawValue:)),
                      let text = f["text"],
                      let ts = f["ts"].flatMap(Int64.init)
                else { return nil }
                let tcs = f["toolCalls"].map(Self.decodeToolCalls) ?? []
                return ChatTurn(
                    id: f["id"] ?? "unknown",
                    role: role, text: text,
                    toolCalls: tcs,
                    toolCallId: f["toolCallId"],
                    timestamp: ts
                )
            },
            config: { b in
                b.timeRange { $0.timestamp }
                b.tags { ["role:\($0.role.rawValue)"] }
            }
        )
        return ChatAgentImpl(
            threadId: threadId,
            memory: memory,
            llm: llm,
            tools: cfg.tools,
            systemPromptTemplate: cfg.systemPrompt,
            systemPromptVars: cfg.systemPromptVars,
            contextWindow: cfg.contextWindow,
            compaction: cfg.compaction,
            execution: cfg.execution,
            maxToolIterations: cfg.maxToolIterations
        )
    }

    private static func encodeToolCalls(_ calls: [ToolCall]) -> String {
        var s = "["
        for (i, c) in calls.enumerated() {
            if i > 0 { s += "|" }
            s += "\(c.id)~\(c.name)~\(c.arguments.replacingOccurrences(of: "|", with: "\\|"))"
        }
        return s + "]"
    }
    private static func decodeToolCalls(_ raw: String) -> [ToolCall] {
        guard raw.count >= 2, raw.first == "[", raw.last == "]" else { return [] }
        let body = String(raw.dropFirst().dropLast())
        if body.isEmpty { return [] }
        return body.split(separator: "|").compactMap { chunk in
            let parts = chunk.split(separator: "~", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return ToolCall(
                id: String(parts[0]),
                name: String(parts[1]),
                arguments: String(parts[2]).replacingOccurrences(of: "\\|", with: "|")
            )
        }
    }
}
