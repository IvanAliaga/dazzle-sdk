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

/// `LLMClient` that speaks Anthropic's `/v1/messages` wire format
/// (Claude). Distinct from `OpenAICompatibleClient` because the
/// Anthropic shape is *not* OpenAI-equivalent:
///
///   * `system` is a top-level field (not a `messages[]` entry);
///   * tool-calls and tool-results are content **blocks** inside
///     `content` arrays, not a parallel `tool_calls` field;
///   * tool schemas live under `input_schema` (vs. `parameters`);
///   * SSE frames carry `event: <name>\ndata: {...}` pairs with
///     `content_block_*` and `message_*` events;
///   * `max_tokens` is **required**.
///
/// ## Example
///
/// ```swift
/// let claude = AnthropicClient(
///     model:     "claude-3-5-sonnet-latest",
///     apiKey:    ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
///     maxTokens: 1024
/// )
/// let completion = try await claude.complete(
///     messages: [Message(role: .user, content: "Hi")],
///     tools: []
/// )
/// ```
///
/// ## Tool-calling
///
/// Both directions are auto-translated, so the agent doesn't notice
/// it's talking to Claude:
///
///   * outbound — `Message.toolCalls` becomes `content: [{type:
///     "tool_use", id, name, input}]`; `tool` role turns become
///     `{role: "user", content: [{type: "tool_result", tool_use_id,
///     content}]}` (Anthropic's contract);
///   * inbound — `tool_use` content blocks emit
///     `Delta.toolCallStart` once their `content_block_start`
///     arrives, and the streamed `input_json_delta` payloads emit
///     `Delta.toolCallArgs`.
///
/// ## Transport
///
/// `URLSession` directly — same playbook as `OpenAICompatibleClient`,
/// no extra dependency. Cancellation propagates through the
/// `AsyncThrowingStream` and aborts the HTTP body.
public final class AnthropicClient: LLMClient, @unchecked Sendable {

    public let modelId: String

    private let baseURL: URL
    private let model: String
    private let apiKey: String
    private let anthropicVersion: String
    private let maxTokens: Int
    private let temperature: Double?
    private let topP: Double?
    private let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        model: String,
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        anthropicVersion: String = "2023-06-01",
        maxTokens: Int = 1024,
        temperature: Double? = nil,
        topP: Double? = nil,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.extraHeaders = extraHeaders
        self.session = session
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

                    // index → (kind, id, name). `kind` is "text" or
                    // "tool_use"; tool-use blocks remember the (id,
                    // name) the caller saw on `content_block_start` so
                    // streamed `input_json_delta` fragments can be
                    // re-tagged with the same id.
                    var liveBlocks: [Int: BlockMeta] = [:]

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                            .trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let obj = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any] else { continue }
                        let type = obj["type"] as? String ?? ""

                        switch type {
                        case "content_block_start":
                            let index = obj["index"] as? Int ?? 0
                            guard let block = obj["content_block"] as? [String: Any] else { break }
                            let kind = block["type"] as? String ?? ""
                            switch kind {
                            case "text":
                                liveBlocks[index] = BlockMeta(kind: "text")
                            case "tool_use":
                                let id = block["id"] as? String ?? "tu_\(index)"
                                let name = block["name"] as? String ?? ""
                                liveBlocks[index] = BlockMeta(
                                    kind: "tool_use", id: id, name: name)
                                continuation.yield(.toolCallStart(id: id, name: name))
                            default:
                                break
                            }

                        case "content_block_delta":
                            let index = obj["index"] as? Int ?? 0
                            guard let delta = obj["delta"] as? [String: Any] else { break }
                            let dtype = delta["type"] as? String ?? ""
                            switch dtype {
                            case "text_delta":
                                if let text = delta["text"] as? String, !text.isEmpty {
                                    continuation.yield(.text(text))
                                }
                            case "input_json_delta":
                                guard let meta = liveBlocks[index],
                                      meta.kind == "tool_use" else { break }
                                if let frag = delta["partial_json"] as? String,
                                   !frag.isEmpty {
                                    continuation.yield(.toolCallArgs(id: meta.id, chunk: frag))
                                }
                            default:
                                break
                            }

                        // message_start, ping, content_block_stop,
                        // message_delta, message_stop — informational,
                        // ignored. The stream ends naturally when
                        // bytes.lines closes.
                        default:
                            break
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
        let url = baseURL.appendingPathComponent("messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(stream ? "text/event-stream" : "application/json",
                     forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try Self.encodeBody(
            model: model,
            messages: messages,
            tools: tools,
            stream: stream,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
        return req
    }

    // MARK: – Encoding

    private static func encodeBody(
        model: String,
        messages: [Message],
        tools: [ToolDeclaration],
        stream: Bool,
        maxTokens: Int,
        temperature: Double?,
        topP: Double?
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
        ]
        if let temperature { body["temperature"] = temperature }
        if let topP { body["top_p"] = topP }

        // Anthropic separates `system` from `messages[]`. Concatenate
        // any role=system turns into one string (the chat agent only
        // injects one today, but be liberal in what you accept).
        let systemText = messages
            .filter { $0.role == .system }
            .map { $0.content }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemText.isEmpty { body["system"] = systemText }

        body["messages"] = buildMessages(messages)

        if !tools.isEmpty {
            body["tools"] = tools.map(wireTool)
        }
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// Re-shape Dazzle `Message`s into Anthropic's `messages[]`. The
    /// tricky pieces:
    ///
    ///   * assistant turns that include `toolCalls` become `content`
    ///     arrays mixing `text` + `tool_use` blocks;
    ///   * `tool` role turns become `user` turns with one
    ///     `tool_result` block (Anthropic doesn't have a dedicated
    ///     `tool` role — tool replies are user-side context);
    ///   * empty assistant `content` blocks are dropped (Anthropic
    ///     400s on blank text).
    private static func buildMessages(_ messages: [Message]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system:
                continue // handled separately

            case .user:
                out.append(["role": "user", "content": m.content])

            case .assistant:
                var blocks: [[String: Any]] = []
                if !m.content.isEmpty {
                    blocks.append(["type": "text", "text": m.content])
                }
                for tc in m.toolCalls {
                    // Dazzle stores arguments as a JSON string;
                    // Anthropic wants the parsed object under
                    // `input`. Falling back to {} keeps the wire
                    // valid even if the model emitted nothing
                    // before the args were complete.
                    let parsed: Any = (try? JSONSerialization.jsonObject(
                        with: tc.arguments.data(using: .utf8) ?? Data("{}".utf8))) ?? [:]
                    blocks.append([
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                        "input": parsed,
                    ])
                }
                if blocks.isEmpty { continue }
                out.append(["role": "assistant", "content": blocks])

            case .tool:
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId ?? "",
                    "content": m.content,
                ]
                out.append(["role": "user", "content": [block]])
            }
        }
        return out
    }

    private static func wireTool(_ d: ToolDeclaration) -> [String: Any] {
        // JsonSchema.serialize() returns a JSON-encoded object schema
        // — round-trip through JSONSerialization to embed inline.
        let schemaJson = d.parameters.serialize().data(using: .utf8) ?? Data("{}".utf8)
        let schemaObj  = (try? JSONSerialization.jsonObject(with: schemaJson)) ?? [:]
        return [
            "name": d.name,
            "description": d.description,
            "input_schema": schemaObj,
        ]
    }

    // MARK: – Non-streaming decode

    private static func decodeNonStreaming(_ data: Data) throws -> Completion {
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw AnthropicError.emptyResponse
        }
        var text = ""
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "tool_use":
                let id   = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? ""
                let inputObj = block["input"] ?? [String: Any]()
                let argsData = (try? JSONSerialization.data(withJSONObject: inputObj))
                    ?? Data("{}".utf8)
                let args = String(data: argsData, encoding: .utf8) ?? "{}"
                calls.append(ToolCall(id: id, name: name, arguments: args))
            default:
                break
            }
        }
        if !calls.isEmpty {
            return .toolCalls(Message(role: .assistant, content: text, toolCalls: calls))
        }
        return .text(Message(role: .assistant, content: text))
    }

    private static func throwIfHTTPError(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        let preview = String(data: body, encoding: .utf8) ?? "<binary>"
        throw AnthropicError.httpError(status: http.statusCode, body: preview)
    }

    /// Streaming bookkeeping — see usage in `stream(...)`.
    private struct BlockMeta {
        let kind: String   // "text" | "tool_use"
        var id: String = ""
        var name: String = ""
    }
}

// MARK: – Error

public enum AnthropicError: Error, LocalizedError {
    case httpError(status: Int, body: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .httpError(let s, let b): return "Anthropic HTTP \(s): \(b)"
        case .emptyResponse:           return "Anthropic response had no content blocks"
        }
    }
}
