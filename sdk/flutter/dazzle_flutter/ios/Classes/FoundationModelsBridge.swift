// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Flutter ↔ native FoundationModelsClient bridge.
//
// Channels:
//   MethodChannel  dev.dazzle.flutter/foundation        — isAvailable (probe)
//   EventChannel   dev.dazzle.flutter/foundation.tokens — one stream per
//                                                         generation, args
//                                                         carry system
//                                                         prompt + messages
//                                                         + tools
//
// Stateless on the iOS side — each `onListen` instantiates a fresh
// FoundationModelsClient, runs the stream, and tears down. Apple's
// on-device model is session-based; no long-lived handle to keep.

import Flutter
import Foundation

@available(iOS 26.0, macOS 26.0, *)
@objc public final class FoundationModelsBridge:
    NSObject, FlutterStreamHandler {

    private let method: FlutterMethodChannel
    private let events: FlutterEventChannel

    // Same EventChannel hardening pattern as `AnthropicBridge.swift`:
    //   * `tasksBySubId` so a late `onCancel` from turn N never
    //     cancels turn N+1's task,
    //   * `streamId` cookie so the dart-side shim can drop
    //     residual frames Flutter's EventChannel buffer sometimes
    //     replays between subscriptions,
    //   * end-of-turn signalled by a `{"type":"end"}` frame only —
    //     never `events(FlutterEndOfEventStream)` (that
    //     permanently kills the channel and breaks every future
    //     turn).
    private var nextSubId: Int = 0
    private var tasksBySubId: [Int: Task<Void, Never>] = [:]

    @objc public init(messenger: FlutterBinaryMessenger) {
        self.method = FlutterMethodChannel(
            name: "dev.dazzle.flutter/foundation",
            binaryMessenger: messenger)
        self.events = FlutterEventChannel(
            name: "dev.dazzle.flutter/foundation.tokens",
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
    }

    // MARK: – MethodChannel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(FoundationModelsClient.isAvailable)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: – EventChannel

    public func onListen(withArguments arguments: Any?,
                        eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let args = arguments as? [String: Any] else {
            return FlutterError(code: "BAD_ARGS", message: "no arguments", details: nil)
        }
        let systemPrompt = (args["systemPrompt"] as? String)
            ?? "You are a helpful on-device AI assistant."
        let temperature = (args["temperature"] as? NSNumber)?.doubleValue
        let maxTokens   = (args["maxTokens"]   as? NSNumber)?.intValue
        let streamId    = (args["streamId"]    as? Int) ?? 0

        let messages = Self.decodeMessages(args["messages"])
        let tools    = Self.decodeTools(args["tools"])

        nextSubId += 1
        let mySubId = nextSubId
        let task = Task { [events, weak self] in
            do {
                let client = FoundationModelsClient(
                    systemPrompt: systemPrompt,
                    temperature: temperature,
                    maxTokens: maxTokens)
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
                // Send `type:"end"` only — never
                // `events(FlutterEndOfEventStream)`. The latter
                // permanently closes the EventChannel and every
                // future `onListen` is silently dropped.
                await MainActor.run {
                    events(["type": "end", "streamId": streamId])
                }
            } catch {
                await MainActor.run {
                    events(FlutterError(code: "FM_STREAM_FAILED",
                                        message: "\(error)",
                                        details: nil))
                }
            }
            await MainActor.run { [weak self] in
                self?.tasksBySubId.removeValue(forKey: mySubId)
            }
        }
        tasksBySubId[mySubId] = task
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        // Intentionally a no-op — see the comment near
        // `tasksBySubId`. A late `onCancel` would otherwise kill
        // the *next* turn's task.
        return nil
    }

    // MARK: – Decoders

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
}
