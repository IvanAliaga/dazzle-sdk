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

import Foundation
#if canImport(Dazzle)
import Dazzle  // SwiftPM consumers — Dazzle is a separate module.
#endif
// Sample apps and the experiment app drop the Dazzle Swift sources
// directly into their target, so `LLMClient`, `Message`, etc. are in
// scope without an import. SPM consumers go through the import above.
import LiteRTLMSwift

/// Default `LLMClient` implementation that runs Gemma / Llama / Qwen
/// on-device via LiteRT-LM. Used by the Layer 3 `DazzleEdge` bundle
/// when the consumer opts into `.liteRTLM` as the backend.
///
/// ## Adding to your app
///
/// ```swift
/// // Package.swift
/// .package(url: "https://github.com/IvanAliaga/dazzle.git", branch: "main"),
///
/// // Target dependencies
/// .product(name: "Dazzle", package: "dazzle"),
/// .product(name: "DazzleLiteRTLM", package: "dazzle"),   // opt-in
/// ```
///
/// **Critical**: on-device you also need a post-build script that re-signs
/// the `CLiteRTLM.framework`'s nested dylib
/// (`libGemmaModelConstraintProvider.dylib`). The script from the
/// experiment `project.yml` works verbatim — copy it into your app's
/// xcodegen manifest. Without it, `dyld` rejects the framework on device
/// with "code signature invalid (errno=1)" even though it loads fine in
/// the simulator.
///
/// ## What this adapter DOES
///
/// - Loads a `.litertlm` model file via the `LiteRTLMEngine` API
/// - Templates the incoming `[Message]` into the runtime's prompt format
/// - Streams completions as `Delta.text` chunks; emits `Delta.end` at
///   the terminal
/// - Cancellation: the caller's `Task` cancellation propagates through
///   the `AsyncThrowingStream` returned by `generateStreaming`.
///
/// ## Tool-calling
///
/// The adapter parses the three mainstream on-device tool-call dialects
/// out of the box: Gemma (`<tool_call>{…}</tool_call>`), Llama 3.x
/// (`<|python_tag|>{…}<|eom_id|>`), and Qwen 2.5. When the caller
/// passes a non-empty `tools` list:
///
/// 1. The adapter appends a dialect-specific `# Tools` section to the
///    system prompt describing each function in the format the model
///    was fine-tuned on.
/// 2. Streamed output is piped through `ToolCallParser`, which emits
///    `.toolCallStart` + `.toolCallArgs` for tool blocks and forwards
///    plain text verbatim as `.text`.
/// 3. `complete()` collects the same stream and assembles the final
///    `Completion.toolCalls` when the model invoked at least one tool.
///
/// The exact dialect is picked by `toolCallSyntax`; `.auto` infers it
/// from the model filename (gemma-/llama-/qwen-).
public final class LiteRtLmClient: LLMClient, @unchecked Sendable {

    public let modelId: String

    private let engine: LiteRTLMEngine
    private let systemPrompt: String
    private let temperature: Float
    private let maxTokens: Int
    private let syntax: ToolCallSyntax

    /// Instantiate. The model is loaded eagerly — call from a background
    /// task if you want to keep the main thread responsive. Expect
    /// 5–10 seconds on an iPhone 12 Pro for a 2.4 GB Gemma model.
    public init(
        modelURL: URL,
        modelId: String? = nil,
        systemPrompt: String = "You are a helpful on-device AI assistant.",
        temperature: Float = 0.01,
        maxTokens: Int = 512,
        toolCallSyntax: ToolCallSyntax = .auto
    ) async throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw DazzleError.modelLoadFailed(
                modelId: modelURL.lastPathComponent,
                underlying: "file does not exist at \(modelURL.path)"
            )
        }
        let resolvedId = modelId ?? modelURL.deletingPathExtension().lastPathComponent
        self.modelId = resolvedId
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.syntax = (toolCallSyntax == .auto)
            ? ToolCallPrompts.detectFromFilename(modelURL.lastPathComponent)
            : toolCallSyntax
        // CPU backend — matches the Android Backend.CPU() choice and
        // avoids Metal memory spikes that OOM a 6 GB iPhone when the
        // 2.4 GB model is already resident.
        self.engine = LiteRTLMEngine(modelPath: modelURL, backend: "cpu")
        do {
            try await engine.load()
        } catch {
            throw DazzleError.modelLoadFailed(
                modelId: resolvedId,
                underlying: error.localizedDescription
            )
        }
    }

    public func complete(
        messages: [Message],
        tools: [ToolDeclaration]
    ) async throws -> Completion {
        var text = ""
        var callNames = [String: String]()      // id → name, insertion order preserved by callOrder
        var callArgs  = [String: String]()
        var callOrder = [String]()
        for try await d in stream(messages: messages, tools: tools) {
            switch d {
            case .text(let t):
                text += t
            case .toolCallStart(let id, let name):
                if callNames[id] == nil { callOrder.append(id) }
                callNames[id] = name
                callArgs[id]  = callArgs[id] ?? ""
            case .toolCallArgs(let id, let chunk):
                callArgs[id, default: ""] += chunk
            case .end:
                break
            }
        }
        if !callOrder.isEmpty {
            let calls = callOrder.map { id in
                ToolCall(
                    id: id,
                    name: callNames[id] ?? "",
                    arguments: callArgs[id] ?? "{}"
                )
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
        let prompt = assemblePrompt(messages: messages, tools: tools)
        let parser = ToolCallParser(syntax: syntax)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in engine.generateStreaming(
                        prompt: prompt,
                        temperature: temperature,
                        maxTokens: maxTokens
                    ) {
                        if !chunk.isEmpty {
                            for d in parser.process(chunk) {
                                continuation.yield(d)
                            }
                        }
                    }
                    for d in parser.flush() {
                        continuation.yield(d)
                    }
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() {
        // LiteRTLMSwift's engine releases its resources when deallocated;
        // no explicit close API.
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// Collapse history into a single prompt string consumable by the
    /// runtime's one-shot `generate(prompt:)` API. The runtime applies
    /// Gemma / Llama / Qwen chat templating internally when the model
    /// ships with a compatible tokenizer config. When `tools` is non-
    /// empty the system prompt is augmented with a dialect-specific
    /// `# Tools` block.
    private func assemblePrompt(messages: [Message], tools: [ToolDeclaration]) -> String {
        let baseSystem = messages.last(where: { $0.role == .system })?.content ?? systemPrompt
        let system = baseSystem + ToolCallPrompts.renderToolsSection(tools, syntax: syntax)
        let turns = messages.filter { $0.role != .system }
        var sb = ""
        sb += "<|system|>\n\(system)\n"
        for t in turns {
            let label: String
            switch t.role {
            case .user: label = "user"
            case .assistant: label = "assistant"
            case .tool: label = "tool"
            case .system: continue
            }
            sb += "<|\(label)|>\n\(t.content)\n"
        }
        sb += "<|assistant|>\n"
        return sb
    }
}
