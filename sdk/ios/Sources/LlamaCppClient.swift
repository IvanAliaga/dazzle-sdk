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
import DazzleC

/// `LLMClient` that runs on-device inference via the embedded
/// llama.cpp (shipped inside `Dazzle.xcframework`). Loads GGUF
/// weight files — every model packaged for llama.cpp on Hugging
/// Face (`*.gguf`) works: Gemma 2/3, Llama 3.x, Qwen 2.5, Phi-4,
/// DeepSeek-R1 distills, Mistral, etc.
///
/// ```swift
/// let model = URL(fileURLWithPath: "/path/to/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf")
/// let llm = try await LlamaCppClient(modelURL: model)
/// let agent = try DazzleEdge.chatAgent(llm: llm)
/// agent.send("Explain quantisation in one sentence.")
/// ```
///
/// Tool-call dialect — same `ToolCallSyntax` / `ToolCallParser`
/// pipeline the `LiteRtLmClient` uses, so Gemma / Llama / Qwen
/// tool output is parsed into `Delta.toolCallStart` /
/// `Delta.toolCallArgs` without any extra work on the caller side.
///
/// ## Threading
///
/// - `init` loads the model + creates the context synchronously on
///   the calling actor; for a 2 GB Q4 file, budget 5-10 s on an
///   iPhone 12 Pro. Call from a `Task.detached` if you need the
///   main thread responsive.
/// - `complete` and `stream` run inference on a private background
///   `DispatchQueue`. Cancellation of the outer `Task` propagates
///   to the generator and stops at the next token boundary.
public final class LlamaCppClient: LLMClient, @unchecked Sendable {

    public let modelId: String

    // Raw llama.cpp handles. The C header forward-declares the
    // structs without body, so Swift imports them as `OpaquePointer?`
    // — we never dereference from Swift, just pass them back to the
    // C helpers.
    private let model: OpaquePointer
    private let ctx:   OpaquePointer

    private let systemPrompt: String
    private let temperature: Float
    private let topP: Float
    private let maxTokens: Int
    private let syntax: ToolCallSyntax
    private let seed: UInt32

    /// Dedicated serial queue — llama.cpp's decode loop is single-
    /// threaded and stateful, so concurrent `stream` calls on the
    /// same instance would corrupt KV cache. Serialising on a
    /// queue is simpler than a mutex and lets the caller `await`
    /// naturally.
    private let queue = DispatchQueue(label: "dev.dazzle.llama", qos: .userInitiated)

    /// Instantiate. Model load is eager — happens on the calling
    /// actor. Throws `DazzleError.modelLoadFailed` when the GGUF
    /// can't be opened.
    public init(
        modelURL: URL,
        modelId: String? = nil,
        systemPrompt: String = "You are a helpful on-device AI assistant.",
        temperature: Float = 0.7,
        topP: Float = 0.95,
        maxTokens: Int = 512,
        nCtx: Int = 2048,
        nThreads: Int = 4,
        nGpuLayers: Int = 0,
        seed: UInt32 = 0xD4_77_1E,
        toolCallSyntax: ToolCallSyntax = .auto
    ) async throws {
        let resolvedId = modelId ?? modelURL.deletingPathExtension().lastPathComponent
        self.modelId = resolvedId
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seed = seed
        self.syntax = (toolCallSyntax == .auto)
            ? ToolCallPrompts.detectFromFilename(modelURL.lastPathComponent)
            : toolCallSyntax

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw DazzleError.modelLoadFailed(
                modelId: modelURL.lastPathComponent,
                underlying: "file does not exist at \(modelURL.path)"
            )
        }
        dazzle_llama_backend_init()

        // llama_load_model_from_file mmaps ~2 GB of weights; take it
        // off the caller's actor to keep the UI thread responsive.
        let loaded: OpaquePointer = try await Task.detached(priority: .userInitiated) {
            guard let handle = modelURL.path.withCString({ path in
                dazzle_llama_load_model(path, Int32(nGpuLayers))
            }) else {
                throw DazzleError.modelLoadFailed(
                    modelId: resolvedId,
                    underlying: "dazzle_llama_load_model returned NULL"
                )
            }
            return handle
        }.value
        self.model = loaded

        guard let ctxHandle = dazzle_llama_new_context(
            loaded, Int32(nCtx), Int32(nThreads)
        ) else {
            dazzle_llama_free_model(loaded)
            throw DazzleError.modelLoadFailed(
                modelId: resolvedId,
                underlying: "dazzle_llama_new_context returned NULL"
            )
        }
        self.ctx = ctxHandle
    }

    deinit {
        dazzle_llama_free_context(ctx)
        dazzle_llama_free_model(model)
    }

    // MARK: – LLMClient

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
        let prompt = assemblePrompt(messages: messages, tools: tools)
        let parser = ToolCallParser(syntax: syntax)
        // INSTRUMENTATION — append the assembled prompt + raw model output
        // to a file in the app's Documents dir so we can pull it with
        // `xcrun devicectl device file pull` and inspect what the model
        // actually sees and emits.
        DazzleDebugLog.writeBlock("=== PROMPT (\(prompt.count)c, syntax=\(syntax)) ===\n\(prompt)\n=== END PROMPT ===\n=== RAW OUTPUT ===\n")

        return AsyncThrowingStream { continuation in
            // Box the continuation + cancellation flag so the @convention(c)
            // callback can see them across the FFI boundary.
            let box = GenerationBox(continuation: continuation, parser: parser)
            let boxPtr = Unmanaged.passRetained(box).toOpaque()

            queue.async { [self] in
                let cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = {
                    (pieceCstr, userData) in
                    guard let pieceCstr, let userData else { return 0 }
                    let b = Unmanaged<GenerationBox>.fromOpaque(userData).takeUnretainedValue()
                    if b.cancelled { return 1 }
                    let piece = String(cString: pieceCstr)
                    DazzleDebugLog.writeRaw(piece)
                    for d in b.parser.process(piece) {
                        b.continuation.yield(d)
                    }
                    return 0
                }

                let rc = prompt.withCString { ptr in
                    dazzle_llama_generate(
                        self.ctx,
                        ptr,
                        Int32(self.maxTokens),
                        self.temperature,
                        self.topP,
                        self.seed,
                        cb,
                        boxPtr
                    )
                }

                // Flush any held-back text and terminate.
                for d in box.parser.flush() { box.continuation.yield(d) }
                DazzleDebugLog.writeBlock("\n=== END RAW OUTPUT (rc=\(rc)) ===\n\n")
                if rc < 0 && rc != Int32(DAZZLE_LLAMA_E_CANCELLED) {
                    box.continuation.finish(throwing: LlamaCppClientError.generationFailed(code: Int(rc)))
                } else {
                    box.continuation.yield(.end)
                    box.continuation.finish()
                }
                Unmanaged<GenerationBox>.fromOpaque(boxPtr).release()
            }

            continuation.onTermination = { _ in
                // Cooperative cancel — the next callback invocation
                // returns 1 and the generator exits at the next
                // token boundary. Won't interrupt the currently
                // running decode tile, which is fine (single token
                // latency).
                let b = Unmanaged<GenerationBox>.fromOpaque(boxPtr).takeUnretainedValue()
                b.cancelled = true
            }
        }
    }

    public func close() {
        // Handles are freed in deinit. Intentionally empty so
        // "close" matches the cheap-to-call semantics other adapters
        // expose; the caller doesn't pay for teardown unless the
        // object is actually released.
    }

    // MARK: – Helpers

    private func assemblePrompt(messages: [Message], tools: [ToolDeclaration]) -> String {
        let baseSystem = messages.last(where: { $0.role == .system })?.content ?? systemPrompt
        let sys = baseSystem + ToolCallPrompts.renderToolsSection(tools, syntax: syntax)
        let turns = messages.filter { $0.role != .system }

        // Dialect-aware chat template. Qwen 2.5 / Qwen 3 were trained with
        // ChatML markers (<|im_start|>role\n...<|im_end|>) — feeding them
        // the generic <|system|>/<|user|>/<|assistant|> wrapper makes the
        // model treat the markers as garbage text and fail on turn 2+.
        // Llama 3.x uses its own header markers; Gemma matches the generic
        // wrapper closely enough.
        switch syntax {
        case .qwen25:
            // Match Qwen 2.5's chat_template.jinja exactly. Three quirks:
            //   1. assistant tool_calls live INSIDE the <|im_start|>assistant
            //      block, not as a separate message.
            //   2. tool results are wrapped as a USER message containing
            //      <tool_response>...</tool_response> — Qwen NEVER sees
            //      role "tool" as a chat-template label.
            //   3. consecutive tool results share a single user wrapper.
            var sb = "<|im_start|>system\n\(sys)<|im_end|>\n"
            var i = 0
            while i < turns.count {
                let t = turns[i]
                switch t.role {
                case .user:
                    sb += "<|im_start|>user\n\(t.content)<|im_end|>\n"
                case .assistant:
                    sb += "<|im_start|>assistant"
                    if !t.content.isEmpty { sb += "\n\(t.content)" }
                    if !t.toolCalls.isEmpty {
                        for call in t.toolCalls {
                            sb += "\n<tool_call>\n{\"name\": \"\(call.name)\", \"arguments\": \(call.arguments)}\n</tool_call>"
                        }
                    }
                    sb += "<|im_end|>\n"
                case .tool:
                    // Open a fresh <|im_start|>user wrapper if the previous
                    // turn wasn't also a tool message.
                    let prevWasTool = (i > 0) && (turns[i - 1].role == .tool)
                    if !prevWasTool { sb += "<|im_start|>user" }
                    sb += "\n<tool_response>\n\(t.content)\n</tool_response>"
                    let nextIsTool = (i + 1 < turns.count) && (turns[i + 1].role == .tool)
                    if !nextIsTool { sb += "<|im_end|>\n" }
                case .system:
                    break  // already handled in the leading sys block
                }
                i += 1
            }
            sb += "<|im_start|>assistant\n"
            return sb

        case .llama32:
            var sb = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(sys)<|eot_id|>"
            for t in turns {
                let label: String
                switch t.role {
                case .user:      label = "user"
                case .assistant: label = "assistant"
                case .tool:      label = "ipython"
                case .system:    continue
                }
                sb += "<|start_header_id|>\(label)<|end_header_id|>\n\n\(t.content)<|eot_id|>"
            }
            sb += "<|start_header_id|>assistant<|end_header_id|>\n\n"
            return sb

        case .gemma, .auto:
            var sb = "<|system|>\n\(sys)\n"
            for t in turns {
                let label: String
                switch t.role {
                case .user:      label = "user"
                case .assistant: label = "assistant"
                case .tool:      label = "tool"
                case .system:    continue
                }
                sb += "<|\(label)|>\n\(t.content)\n"
            }
            sb += "<|assistant|>\n"
            return sb
        }
    }
}

// MARK: – Error

public enum LlamaCppClientError: Error, LocalizedError {
    case generationFailed(code: Int)
    public var errorDescription: String? {
        switch self {
        case .generationFailed(let code):
            return "dazzle_llama_generate returned \(code). See dazzle_llama.h DAZZLE_LLAMA_E_* for meaning."
        }
    }
}

// MARK: – Callback box

/// Captures the stream continuation + parser + cancel flag so the
/// `@convention(c)` callback can reach them via `user_data`. Kept
/// `internal final class` so the memory layout is obvious to the
/// raw-pointer round-trip below.
private final class GenerationBox {
    let continuation: AsyncThrowingStream<Delta, Error>.Continuation
    let parser: ToolCallParser
    var cancelled: Bool = false
    init(
        continuation: AsyncThrowingStream<Delta, Error>.Continuation,
        parser: ToolCallParser
    ) {
        self.continuation = continuation
        self.parser = parser
    }
}
