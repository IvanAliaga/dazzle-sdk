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

#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// `LLMClient` backed by Apple's on-device Foundation Models —
/// the ~3 B-parameter model Apple ships inside iOS 26 / macOS 26
/// as part of Apple Intelligence. Free at runtime: no weights to
/// download, no API key, no cloud round-trip.
///
/// ## When to use
///
/// - iOS 26+ / macOS 26+ on Apple Intelligence-eligible hardware
///   (iPhone 15 Pro or newer, M-series Mac / iPad).
/// - Privacy-first apps that must not send user turns off-device
///   and can't afford to ship a 2 GB GGUF.
/// - Drop-in: `DazzleEdge.chatAgent(llm: FoundationModelsClient())`.
///
/// On older OSes or Apple Intelligence-ineligible devices, check
/// `FoundationModelsClient.isAvailable` and fall back to
/// `LiteRtLmClient` / `LlamaCppClient` / `OpenAICompatibleClient`.
///
/// ## Tool-calling
///
/// Apple's Foundation Models has its own native Tool protocol that
/// requires concrete Swift types. Mapping `Dazzle.ToolDeclaration`
/// (which carries a JSON Schema) onto it would need code
/// generation, so in this first cut we surface `tools` only via
/// the `ToolCallParser` pipeline: Foundation Models' streamed text
/// passes through the same parser the other adapters use, turning
/// `<tool_call>…</tool_call>` (or Llama / Qwen equivalents) back
/// into `Delta.toolCallStart` + `Delta.toolCallArgs`. Works when
/// the model is prompted to emit tool calls in the Gemma dialect
/// — the default we set up with `ToolCallSyntax.gemma`.
///
/// ## Threading
///
/// Apple's API is already async; we don't need a private queue.
/// `stream` wraps the framework's `ResponseStream` as an
/// `AsyncThrowingStream<Delta, Error>` by diffing cumulative
/// snapshots into incremental text chunks.
@available(iOS 26.0, macOS 26.0, *)
public final class FoundationModelsClient: LLMClient, @unchecked Sendable {

    public let modelId: String = "apple:foundation-models"

    private let systemPrompt: String
    private let temperature: Double?
    private let maxTokens: Int?
    private let syntax: ToolCallSyntax

    /// `true` when the default Foundation Models pipeline is ready
    /// on this device. Apple reports availability as an enum with
    /// reasons (model not downloaded, device not eligible, etc.);
    /// a consumer that needs to distinguish should read
    /// `SystemLanguageModel.default.availability` directly.
    public static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default:         return false
        }
    }

    public init(
        systemPrompt: String = "You are a helpful on-device AI assistant.",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        toolCallSyntax: ToolCallSyntax = .gemma
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.syntax = (toolCallSyntax == .auto) ? .gemma : toolCallSyntax
    }

    public func complete(
        messages: [Message],
        tools: [ToolDeclaration]
    ) async throws -> Completion {
        var text = ""
        var callNames  = [String: String]()
        var callArgs   = [String: String]()
        var callOrder  = [String]()
        for try await d in stream(messages: messages, tools: tools) {
            switch d {
            case .text(let t): text += t
            case .toolCallStart(let id, let name):
                if callNames[id] == nil { callOrder.append(id) }
                callNames[id] = name
                callArgs[id]  = callArgs[id] ?? ""
            case .toolCallArgs(let id, let chunk):
                callArgs[id, default: ""] += chunk
            case .end: break
            }
        }
        if !callOrder.isEmpty {
            let calls = callOrder.map {
                ToolCall(id: $0, name: callNames[$0] ?? "", arguments: callArgs[$0] ?? "{}")
            }
            return .toolCalls(Message(role: .assistant, content: "", toolCalls: calls))
        }
        return .text(Message(
            role: .assistant,
            content: text.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    public func stream(
        messages: [Message],
        tools: [ToolDeclaration]
    ) -> AsyncThrowingStream<Delta, Error> {
        let instr = assembleInstructions(messages: messages, tools: tools)
        let prompt = messages.last(where: { $0.role == .user })?.content ?? ""
        let options = makeOptions()
        let parser = ToolCallParser(syntax: syntax)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instr)
                    var emitted = ""
                    for try await partial in session.streamResponse(to: prompt, options: options) {
                        if Task.isCancelled { break }
                        // Apple returns `Snapshot` wrappers where
                        // `.content` is the cumulative String so far.
                        let snapshot = partial.content
                        let deltaText: String
                        if snapshot.count >= emitted.count, snapshot.hasPrefix(emitted) {
                            let idx = snapshot.index(snapshot.startIndex, offsetBy: emitted.count)
                            deltaText = String(snapshot[idx...])
                        } else {
                            // Non-monotonic rewrite — reset.
                            deltaText = snapshot
                        }
                        emitted = snapshot
                        if deltaText.isEmpty { continue }
                        for d in parser.process(deltaText) {
                            continuation.yield(d)
                        }
                    }
                    for d in parser.flush() { continuation.yield(d) }
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() {}

    // MARK: – Helpers

    private func makeOptions() -> GenerationOptions {
        var opts = GenerationOptions()
        if let temperature { opts.temperature = temperature }
        if let maxTokens   { opts.maximumResponseTokens = maxTokens }
        return opts
    }

    /// Build the `instructions` string Apple's LanguageModelSession
    /// seeds every turn with. We fold the caller's system prompt,
    /// the prior conversation (minus the final user turn, which
    /// becomes the prompt argument to `respond` / `streamResponse`),
    /// and the tool declarations block in a dialect the
    /// ToolCallParser understands.
    private func assembleInstructions(
        messages: [Message],
        tools: [ToolDeclaration]
    ) -> String {
        let baseSystem = messages.last(where: { $0.role == .system })?.content ?? systemPrompt
        var sb = baseSystem
        sb += ToolCallPrompts.renderToolsSection(tools, syntax: syntax)
        // Drop the trailing user turn — that's passed to respond()
        // separately so Foundation Models distinguishes the
        // "current question" from the history.
        let userTurns = messages.filter { $0.role != .system }
        let historyCount = (userTurns.last?.role == .user) ? userTurns.count - 1 : userTurns.count
        if historyCount > 0 {
            sb += "\n\n# Prior conversation\n"
            for i in 0..<historyCount {
                let t = userTurns[i]
                let label: String
                switch t.role {
                case .user:      label = "User"
                case .assistant: label = "Assistant"
                case .tool:      label = "Tool"
                case .system:    continue
                }
                sb += "\(label): \(t.content)\n"
            }
        }
        return sb
    }
}

#else
// Framework absent on this OS — keep the type symbol visible so
// callers can pattern-match without `#if canImport` at every site.
public enum FoundationModelsClientUnavailable {}
#endif
