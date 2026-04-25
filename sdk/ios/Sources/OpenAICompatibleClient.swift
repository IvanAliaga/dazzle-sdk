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

/// `LLMClient` that speaks the OpenAI `chat/completions` wire format.
///
/// Any host that serves `/v1/chat/completions` with the OpenAI
/// schema works: OpenAI itself, Azure OpenAI, Groq, Together AI,
/// HuggingFace Inference Providers (`router.huggingface.co/v1`),
/// Ollama local (`localhost:11434/v1`), vLLM, LM Studio, an
/// OpenRouter proxy, or any FastAPI you write yourself.
///
/// ## Examples
///
/// ```swift
/// // OpenAI
/// let openai = OpenAICompatibleClient(
///     baseURL: URL(string: "https://api.openai.com/v1")!,
///     model: "gpt-4o-mini",
///     apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
/// )
///
/// // HuggingFace Inference (any HF-hosted model)
/// let hf = OpenAICompatibleClient(
///     baseURL: URL(string: "https://router.huggingface.co/v1")!,
///     model: "meta-llama/Llama-3.3-70B-Instruct",
///     apiKey: ProcessInfo.processInfo.environment["HF_TOKEN"]
/// )
///
/// // Ollama running on the dev machine, reachable from the simulator
/// let ollama = OpenAICompatibleClient(
///     baseURL: URL(string: "http://localhost:11434/v1")!,
///     model: "llama3.2"
/// )
/// ```
///
/// Native tool-call emission: when the remote reply includes
/// `tool_calls`, they are surfaced as `Delta.toolCallStart` /
/// `Delta.toolCallArgs` on the stream (and as `Completion.toolCalls`
/// from `complete`). No extra parser needed — the wire format is
/// already structured.
///
/// ## Transport
///
/// Uses `URLSession` directly, no external dependency. Streaming
/// parses SSE (`data: {...}\n\n`) with a hand-rolled buffer reader.
/// Cancellation: the caller's Task cancellation propagates through
/// the `AsyncThrowingStream` and aborts the HTTP body.
///
/// ## Security
///
/// HTTPS is enforced by iOS App Transport Security by default. To
/// reach a plain-HTTP host (e.g. local Ollama on `http://`), the
/// consumer app must opt in via `NSAppTransportSecurity` in its
/// `Info.plist` — the SDK does not disable ATS for you.
public final class OpenAICompatibleClient: LLMClient, @unchecked Sendable {

    public let modelId: String

    private let baseURL: URL
    private let model: String
    private let apiKey: String?
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let temperature: Double?
    private let maxTokens: Int?

    public init(
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.session = session
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.modelId = model
    }

    // MARK: – LLMClient

    public func complete(
        messages: [Message],
        tools: [ToolDeclaration]
    ) async throws -> Completion {
        let req = try buildRequest(messages: messages, tools: tools, stream: false)
        let (data, response) = try await session.data(for: req)
        try Self.throwIfHTTPError(response: response, body: data)
        return try Self.decodeNonStreaming(data)
    }

    public func stream(
        messages: [Message],
        tools: [ToolDeclaration]
    ) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try self.buildRequest(messages: messages, tools: tools, stream: true)
                    let (bytes, response) = try await self.session.bytes(for: req)
                    try Self.throwIfHTTPError(response: response, body: Data())

                    // Streaming tool_call accumulator — upstream sends
                    // argument fragments across many chunks with a shared
                    // index / id.
                    var liveCalls: [Int: (id: String, name: String)] = [:]

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        // SSE frames look like `data: {...}` with empty
                        // lines between events. We only care about the
                        // JSON payload lines.
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(StreamChunk.self, from: data)
                        guard let choice = chunk.choices.first else { continue }
                        if let text = choice.delta.content, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        for tc in choice.delta.tool_calls ?? [] {
                            if let name = tc.function?.name {
                                // First fragment for this index — emit
                                // toolCallStart and remember the id.
                                let id = tc.id ?? "tc_\(tc.index)"
                                liveCalls[tc.index] = (id: id, name: name)
                                continuation.yield(.toolCallStart(id: id, name: name))
                            }
                            if let args = tc.function?.arguments,
                               let (id, _) = liveCalls[tc.index] {
                                continuation.yield(.toolCallArgs(id: id, chunk: args))
                            }
                        }
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

    public func close() { /* URLSession is process-shared; nothing to release. */ }

    // MARK: – Request builder

    private func buildRequest(
        messages: [Message],
        tools: [ToolDeclaration],
        stream: Bool
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if stream {
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else {
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try Self.encodeBody(
            model: model,
            messages: messages,
            tools: tools,
            stream: stream,
            temperature: temperature,
            maxTokens: maxTokens
        )
        return req
    }

    // MARK: – Encoding / decoding

    private static func encodeBody(
        model: String,
        messages: [Message],
        tools: [ToolDeclaration],
        stream: Bool,
        temperature: Double?,
        maxTokens: Int?
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages.map(wireMessage),
        ]
        if let temperature { body["temperature"] = temperature }
        if let maxTokens { body["max_tokens"] = maxTokens }
        if !tools.isEmpty {
            body["tools"] = tools.map(wireTool)
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// Map one `Message` to the OpenAI wire shape. The assistant turn
    /// that CARRIES tool calls populates `tool_calls` with parsed JSON
    /// objects; tool responses use `role=tool` + `tool_call_id`.
    private static func wireMessage(_ m: Message) -> [String: Any] {
        var out: [String: Any] = ["role": m.role.rawValue]
        out["content"] = m.content
        if !m.toolCalls.isEmpty {
            out["tool_calls"] = m.toolCalls.map { tc -> [String: Any] in
                [
                    "id": tc.id,
                    "type": "function",
                    "function": [
                        "name": tc.name,
                        // Arguments are a raw JSON string in our model
                        // and OpenAI wants a JSON string too — pass as-is.
                        "arguments": tc.arguments,
                    ],
                ]
            }
        }
        if let id = m.toolCallId { out["tool_call_id"] = id }
        return out
    }

    private static func wireTool(_ d: ToolDeclaration) -> [String: Any] {
        // JsonSchema.serialize() already returns the OpenAI-compatible
        // JSON Schema for an object type, so we round-trip it through
        // JSONSerialization to embed the resulting dictionary inline.
        let schemaJson = d.parameters.serialize().data(using: .utf8) ?? Data("{}".utf8)
        let schemaObj  = (try? JSONSerialization.jsonObject(with: schemaJson)) ?? [:]
        return [
            "type": "function",
            "function": [
                "name": d.name,
                "description": d.description,
                "parameters": schemaObj,
            ],
        ]
    }

    private static func decodeNonStreaming(_ data: Data) throws -> Completion {
        let reply = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
        guard let choice = reply.choices.first else {
            throw OpenAICompatibleError.emptyResponse
        }
        let message = choice.message
        if let calls = message.tool_calls, !calls.isEmpty {
            let mapped = calls.map { c in
                ToolCall(
                    id: c.id,
                    name: c.function?.name ?? "",
                    arguments: c.function?.arguments ?? "{}"
                )
            }
            return .toolCalls(Message(role: .assistant, content: "", toolCalls: mapped))
        }
        return .text(Message(role: .assistant, content: message.content ?? ""))
    }

    private static func throwIfHTTPError(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        let preview = String(data: body, encoding: .utf8) ?? "<binary>"
        throw OpenAICompatibleError.httpError(status: http.statusCode, body: preview)
    }
}

// MARK: – Wire types

/// Non-streaming reply: one `choices[0].message` carries either plain
/// text in `content` or `tool_calls` (an array of function invocations).
private struct NonStreamingResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: MessageBody
    }
    struct MessageBody: Decodable {
        let content: String?
        let tool_calls: [ToolCallBody]?
    }
    struct ToolCallBody: Decodable {
        let id: String
        let function: FunctionBody?
    }
    struct FunctionBody: Decodable {
        let name: String?
        let arguments: String?
    }
}

/// One SSE streaming chunk. Each chunk carries delta-only payload;
/// concatenate `choices[0].delta.content` across chunks to rebuild
/// the final text, and merge `choices[0].delta.tool_calls[i]` by
/// `index` to assemble the argument JSON.
private struct StreamChunk: Decodable {
    let choices: [StreamChoice]
    struct StreamChoice: Decodable {
        let delta: Delta
    }
    struct Delta: Decodable {
        let content: String?
        let tool_calls: [ToolCallFragment]?
    }
    struct ToolCallFragment: Decodable {
        let index: Int
        let id: String?
        let function: FunctionFragment?
    }
    struct FunctionFragment: Decodable {
        let name: String?
        let arguments: String?
    }
}

// MARK: – Error

public enum OpenAICompatibleError: Error, LocalizedError {
    case httpError(status: Int, body: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .httpError(let s, let b): return "OpenAI-compatible HTTP \(s): \(b)"
        case .emptyResponse:           return "OpenAI-compatible response had no choices"
        }
    }
}
