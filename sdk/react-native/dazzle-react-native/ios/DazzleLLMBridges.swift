// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// React Native bridges for LlamaCppClient + FoundationModelsClient.
// Mirrors the Flutter plugin's equivalents — each `create` instantiates
// a native SDK client and stores it under an auto-incrementing int
// handle. `generate` runs the stream inside a Task and re-emits each
// Delta through the RN event bus via
// `DazzleReactNative.emitEventName(...)` (an ObjC++ entry point).

import Foundation

@objc(DazzleLLMBridges)
public class DazzleLLMBridges: NSObject {

    @objc public static let shared = DazzleLLMBridges()

    private let queue = DispatchQueue(label: "dev.dazzle.rn.llm",
                                      qos: .userInitiated)
    private var nextHandle: Int32 = 1
    private var llamaClients: [Int32: LlamaCppClient] = [:]
    private var fmClients:    [Int32: Any] = [:]   // iOS 26 API availability
    private var activeTasks:  [Int32: Task<Void, Never>] = [:]

    private override init() {}

    /// ObjC++ sets this at module init so the Swift bridges have a
    /// one-way path to emit RCT events without needing a reference to
    /// the emitter type (which would drag RCTEventEmitter imports
    /// across the module boundary).
    @objc public var emit: ((String, [String: Any]) -> Void)?

    // MARK: – LlamaCpp

    @objc public func llamaCreate(
        opts: [String: Any],
        resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        queue.async { [self] in
            Task {
                do {
                    guard let modelPath = opts["modelPath"] as? String else {
                        return reject("BAD_ARGS", "modelPath required", nil)
                    }
                    let systemPrompt = (opts["systemPrompt"] as? String)
                        ?? "You are a helpful on-device AI assistant."
                    let temperature = (opts["temperature"] as? NSNumber)?.floatValue ?? 0.3
                    let topP        = (opts["topP"]        as? NSNumber)?.floatValue ?? 0.95
                    let maxTokens   = (opts["maxTokens"]   as? Int) ?? 512
                    let nCtx        = (opts["nCtx"]        as? Int) ?? 2048
                    let nThreads    = (opts["nThreads"]    as? Int) ?? 4

                    let client = try await LlamaCppClient(
                        modelURL: URL(fileURLWithPath: modelPath),
                        systemPrompt: systemPrompt,
                        temperature: temperature,
                        topP: topP,
                        maxTokens: maxTokens,
                        nCtx: nCtx,
                        nThreads: nThreads)

                    let handle = OSAtomicIncrement32(&self.nextHandle)
                    llamaClients[handle] = client
                    resolve(NSNumber(value: handle))
                } catch {
                    reject("LLAMA_CREATE_FAILED",
                           "\(type(of: error)): \(error.localizedDescription)",
                           nil)
                }
            }
        }
    }

    @objc public func llamaGenerate(
        opts: [String: Any],
        resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        guard let handle = (opts["handle"] as? NSNumber)?.int32Value,
              let client = llamaClients[handle] else {
            return reject("NO_HANDLE", "llama handle not found", nil)
        }
        guard let reqId = (opts["reqId"] as? NSNumber)?.int32Value else {
            return reject("BAD_ARGS", "reqId required", nil)
        }
        let messages = Self.decodeMessages(opts["messages"])
        let tools    = Self.decodeTools(opts["tools"])

        activeTasks[reqId]?.cancel()
        activeTasks[reqId] = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await d in client.stream(messages: messages, tools: tools) {
                    let frame: [String: Any] = Self.deltaToDict(d, reqId: reqId)
                    await MainActor.run { self.emit?("onLlamaToken", frame) }
                }
                await MainActor.run {
                    self.emit?("onLlamaToken",
                               ["reqId": NSNumber(value: reqId), "type": "end"])
                }
            } catch {
                await MainActor.run {
                    self.emit?("onLlamaToken",
                               ["reqId": NSNumber(value: reqId),
                                "type": "error",
                                "message": error.localizedDescription])
                }
            }
            await MainActor.run { self.activeTasks.removeValue(forKey: reqId) }
        }
        resolve(nil)
    }

    @objc public func llamaClose(
        handle: NSNumber,
        resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        if let c = llamaClients.removeValue(forKey: handle.int32Value) {
            Task { await c.close() }
        }
        resolve(nil)
    }

    // MARK: – Foundation Models

    @objc public func fmIsAvailable(
        resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        if #available(iOS 26.0, macOS 26.0, *) {
            resolve(FoundationModelsClient.isAvailable)
        } else {
            resolve(false)
        }
    }

    @objc public func fmGenerate(
        opts: [String: Any],
        resolve: @escaping (Any?) -> Void,
        reject: @escaping (String, String, NSError?) -> Void
    ) {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return reject("FM_UNAVAILABLE",
                "FoundationModelsClient requires iOS/macOS 26+", nil)
        }
        guard let reqId = (opts["reqId"] as? NSNumber)?.int32Value else {
            return reject("BAD_ARGS", "reqId required", nil)
        }
        let systemPrompt = (opts["systemPrompt"] as? String)
            ?? "You are a helpful on-device AI assistant."
        let temperature = (opts["temperature"] as? NSNumber)?.doubleValue
        let maxTokens   = (opts["maxTokens"]   as? NSNumber)?.intValue

        let messages = Self.decodeMessages(opts["messages"])
        let tools    = Self.decodeTools(opts["tools"])

        activeTasks[reqId]?.cancel()
        activeTasks[reqId] = Task { [weak self] in
            guard let self = self else { return }
            do {
                let client = FoundationModelsClient(
                    systemPrompt: systemPrompt,
                    temperature: temperature,
                    maxTokens: maxTokens)
                for try await d in client.stream(messages: messages, tools: tools) {
                    await MainActor.run {
                        self.emit?("onFoundationToken",
                                   Self.deltaToDict(d, reqId: reqId))
                    }
                }
                await MainActor.run {
                    self.emit?("onFoundationToken",
                               ["reqId": NSNumber(value: reqId), "type": "end"])
                }
            } catch {
                await MainActor.run {
                    self.emit?("onFoundationToken",
                               ["reqId": NSNumber(value: reqId),
                                "type": "error",
                                "message": error.localizedDescription])
                }
            }
            await MainActor.run { self.activeTasks.removeValue(forKey: reqId) }
        }
        resolve(nil)
    }

    // MARK: – Shared decoders

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
            let content = (m["content"] as? String) ?? ""
            let toolCallId = m["toolCallId"] as? String
            let toolCalls: [ToolCall] = {
                guard let raw = m["toolCalls"] as? [[String: Any]] else { return [] }
                return raw.compactMap { c -> ToolCall? in
                    guard let id = c["id"] as? String,
                          let name = c["name"] as? String else { return nil }
                    return ToolCall(
                        id: id, name: name,
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
            let json = (t["parameters"] as? String) ?? "{\"type\":\"object\"}"
            return ToolDeclaration(
                name: name, description: description,
                parameters: .raw(json: json))
        }
    }

    private static func deltaToDict(_ d: Delta, reqId: Int32) -> [String: Any] {
        let rid = NSNumber(value: reqId)
        switch d {
        case .text(let t):
            return ["reqId": rid, "type": "text", "chunk": t]
        case .toolCallStart(let id, let name):
            return ["reqId": rid, "type": "toolCallStart",
                    "id": id, "name": name]
        case .toolCallArgs(let id, let chunk):
            return ["reqId": rid, "type": "toolCallArgs",
                    "id": id, "chunk": chunk]
        case .end:
            return ["reqId": rid, "type": "end"]
        }
    }
}
