// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Flutter ↔ native AnthropicClient bridge (iOS).
//
// Channels:
//   MethodChannel  dev.dazzle.flutter/anthropic         — create, close,
//                                                         complete (non-streaming)
//   EventChannel   dev.dazzle.flutter/anthropic.tokens  — one stream per
//                                                         generation, args
//                                                         carry handle +
//                                                         messages + tools
//
// Handle-based so the Dart-side `AnthropicClient` keeps the same
// (model, apiKey, baseURL, version, maxTokens) per-instance options
// across many turns — mirrors the LiteRT bridge so the wire stays
// uniform.

import Flutter
import Foundation

@objc public final class AnthropicBridge: NSObject, FlutterStreamHandler {

    private let method: FlutterMethodChannel
    private let events: FlutterEventChannel

    // handle → live AnthropicClient. Auto-incrementing int returned to
    // the Dart side from `create`. Concurrent map access on the main
    // thread (channel callbacks always land there) so no lock needed.
    private var nextHandle: Int = 1
    private var clients: [Int: AnthropicClient] = [:]

    // ────────────────────────────────────────────────────────────────
    // Per-subscription Task tracking — NOT a single `activeTask`.
    //
    // Why: when a chat turn completes and the dart-side closes its
    // subscription, Flutter posts an `onCancel` to the platform
    // thread asynchronously. If the agent immediately issues turn
    // N+1, that turn's `onListen` lands BEFORE the previous
    // `onCancel` does. With a single `activeTask` member, the late
    // `onCancel` ends up cancelling turn N+1's task, killing its
    // `URLSessionTask` with `NSURLErrorCancelled` and the user sees
    // an empty assistant reply.
    //
    // Fix: each `onListen` owns its own entry in `tasksBySubId` and
    // self-deregisters on completion; `onCancel` is a no-op (we
    // intentionally drop dart-side cancellation hints). On plugin
    // detach, `dispose()` cancels everything still in-flight.
    // ────────────────────────────────────────────────────────────────
    private var nextSubId: Int = 0
    private var tasksBySubId: [Int: Task<Void, Never>] = [:]

    @objc public init(messenger: FlutterBinaryMessenger) {
        self.method = FlutterMethodChannel(
            name: "dev.dazzle.flutter/anthropic",
            binaryMessenger: messenger)
        self.events = FlutterEventChannel(
            name: "dev.dazzle.flutter/anthropic.tokens",
            binaryMessenger: messenger)
        super.init()
        method.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        events.setStreamHandler(self)
    }

    @objc public func dispose() {
        method.setMethodCallHandler(nil)
        events.setStreamHandler(nil)
        for (_, task) in tasksBySubId { task.cancel() }
        tasksBySubId.removeAll()
        clients.removeAll()
    }

    // MARK: – MethodChannel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "create":   doCreate(call, result)
        case "close":    doClose(call, result)
        case "complete": doComplete(call, result)
        default:         result(FlutterMethodNotImplemented)
        }
    }

    private func doCreate(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let model = args["model"] as? String,
              let apiKey = args["apiKey"] as? String else {
            result(FlutterError(code: "BAD_ARGS",
                                message: "model and apiKey are required",
                                details: nil))
            return
        }
        let baseURLStr = (args["baseURL"] as? String) ?? "https://api.anthropic.com/v1"
        guard let baseURL = URL(string: baseURLStr) else {
            result(FlutterError(code: "BAD_ARGS",
                                message: "invalid baseURL: \(baseURLStr)",
                                details: nil))
            return
        }
        let version    = (args["anthropicVersion"] as? String) ?? "2023-06-01"
        let maxTokens  = (args["maxTokens"]    as? NSNumber)?.intValue ?? 1024
        let temperature = (args["temperature"] as? NSNumber)?.doubleValue
        let topP        = (args["topP"]        as? NSNumber)?.doubleValue
        let extraHeaders = (args["extraHeaders"] as? [String: Any])?
            .compactMapValues { $0 as? String } ?? [:]

        let client = AnthropicClient(
            model: model,
            apiKey: apiKey,
            baseURL: baseURL,
            anthropicVersion: version,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            extraHeaders: extraHeaders)
        let handle = nextHandle
        nextHandle += 1
        clients[handle] = client
        result(handle)
    }

    private func doClose(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let handle = args["handle"] as? Int else {
            result(nil); return
        }
        clients.removeValue(forKey: handle)?.close()
        result(nil)
    }

    private func doComplete(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let handle = args["handle"] as? Int,
              let client = clients[handle] else {
            result(FlutterError(code: "NO_HANDLE",
                                message: "handle missing or unknown",
                                details: nil))
            return
        }
        let messages = Self.decodeMessages(args["messages"])
        let tools    = Self.decodeTools(args["tools"])
        Task {
            do {
                let completion = try await client.complete(
                    messages: messages, tools: tools)
                let frame = Self.encodeCompletion(completion)
                await MainActor.run { result(frame) }
            } catch {
                await MainActor.run {
                    result(FlutterError(code: "ANTHROPIC_COMPLETE_FAILED",
                                        message: "\(error)",
                                        details: nil))
                }
            }
        }
    }

    // MARK: – EventChannel
    //
    // args = {
    //   'handle': Int,
    //   'messages': [{ role, content, toolCallId?, toolCalls? }, …],
    //   'tools':    [{ name, description, parameters }, …],
    // }

    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let args = arguments as? [String: Any] else {
            return FlutterError(code: "BAD_ARGS", message: "no arguments", details: nil)
        }
        guard let handle = args["handle"] as? Int,
              let client = clients[handle] else {
            return FlutterError(code: "NO_HANDLE",
                                message: "handle missing or unknown",
                                details: nil)
        }
        let messages = Self.decodeMessages(args["messages"])
        let tools    = Self.decodeTools(args["tools"])
        // streamId cookie — the dart-side shim drops frames whose
        // streamId doesn't match the cookie it asked for. Defends
        // against EventChannel buffer replay from a previous turn.
        let streamId = args["streamId"] as? Int ?? 0

        nextSubId += 1
        let mySubId = nextSubId

        let task = Task { [events, weak self] in
            do {
                for try await d in client.stream(messages: messages, tools: tools) {
                    var frame: [String: Any]
                    switch d {
                    case .text(let t):
                        frame = ["type": "text", "chunk": t]
                    case .toolCallStart(let id, let name):
                        frame = ["type": "toolCallStart", "id": id, "name": name]
                    case .toolCallArgs(let id, let chunk):
                        frame = ["type": "toolCallArgs", "id": id, "chunk": chunk]
                    case .end:
                        frame = ["type": "end"]
                    }
                    frame["streamId"] = streamId
                    await MainActor.run { events(frame) }
                }
                // Send `type:"end"` so the dart-side StreamController
                // closes; do NOT call `events(FlutterEndOfEventStream)`
                // — that permanently kills the EventChannel, blocking
                // every subsequent turn.
                await MainActor.run {
                    events(["type": "end", "streamId": streamId])
                }
            } catch {
                await MainActor.run {
                    events(FlutterError(code: "ANTHROPIC_STREAM_FAILED",
                                        message: "\(error)",
                                        details: nil))
                }
            }
            // Self-deregister when the task ends naturally — keeps
            // the FIFO order in `onCancel` correct so we never
            // cancel the wrong subscription.
            await MainActor.run { [weak self] in
                self?.tasksBySubId.removeValue(forKey: mySubId)
            }
        }
        tasksBySubId[mySubId] = task
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        // Intentionally a no-op.
        //
        // Why: Flutter `EventChannel.onCancel` lands on the platform
        // thread *asynchronously* after the dart-side closes its
        // subscription. In a chat agent, the next turn's `onListen`
        // typically lands BEFORE that cancel does — so cancelling
        // here ends up killing the wrong task (the new turn's HTTP
        // request gets NSURLErrorCancelled mid-flight). Worse, if
        // the previous task already auto-removed itself from the
        // dict on natural completion, `keys.min()` resolves to the
        // *new* turn's id and we cancel it.
        //
        // The streams we run finish in seconds (haiku-4-5 reply
        // takes ~1–2 s per turn), and dispose() fires on plugin
        // detach to cancel anything still in-flight. So we
        // intentionally drop dart-side cancellation hints; tasks
        // self-deregister on completion.
        return nil
    }

    // MARK: – Wire decoding

    private static func decodeMessages(_ raw: Any?) -> [Message] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { m -> Message? in
            let role: Role = {
                switch m["role"] as? String {
                case "system":    return .system
                case "assistant": return .assistant
                case "tool":      return .tool
                default:          return .user
                }
            }()
            let content   = (m["content"] as? String) ?? ""
            let toolCallId = m["toolCallId"] as? String
            let toolCalls: [ToolCall] = {
                guard let raw = m["toolCalls"] as? [[String: Any]] else { return [] }
                return raw.compactMap { c in
                    guard let id = c["id"] as? String,
                          let name = c["name"] as? String
                    else { return nil }
                    return ToolCall(
                        id: id,
                        name: name,
                        arguments: (c["arguments"] as? String) ?? "{}")
                }
            }()
            return Message(role: role,
                           content: content,
                           toolCalls: toolCalls,
                           toolCallId: toolCallId)
        }
    }

    private static func decodeTools(_ raw: Any?) -> [ToolDeclaration] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { t -> ToolDeclaration? in
            guard let name = t["name"] as? String else { return nil }
            let description = (t["description"] as? String) ?? ""
            let schemaStr = (t["parameters"] as? String) ?? "{\"type\":\"object\"}"
            return ToolDeclaration(
                name: name,
                description: description,
                parameters: .raw(json: schemaStr))
        }
    }

    private static func encodeCompletion(_ c: Completion) -> [String: Any] {
        switch c {
        case .text(let m):
            return ["type": "text", "content": m.content]
        case .toolCalls(let m):
            return [
                "type": "toolCalls",
                "content": m.content,
                "toolCalls": m.toolCalls.map { tc in
                    ["id": tc.id, "name": tc.name, "arguments": tc.arguments]
                },
            ]
        }
    }
}
