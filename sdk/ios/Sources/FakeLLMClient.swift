// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// In-memory scripted `LLMClient` for unit tests.
///
/// Returns the next entry from a fixed script each time `complete` or
/// `stream` is called. The dev writes the exact sequence of assistant
/// replies (text or tool_calls) they expect the agent to produce, and
/// the agent's tool-call loop runs against that script without loading
/// a real model.
public final class FakeLLMClient: LLMClient, @unchecked Sendable {

    public let modelId: String
    private let script: [Completion]
    private let streamChunkSize: Int
    private let chunkDelayNanos: UInt64

    private let lock = NSLock()
    private var cursor = 0
    private var _observedHistories: [[Message]] = []

    public init(
        modelId: String = "fake:test",
        script: [Completion],
        streamChunkSize: Int = 8,
        chunkDelayMs: UInt64 = 0
    ) {
        self.modelId = modelId
        self.script = script
        self.streamChunkSize = max(1, streamChunkSize)
        self.chunkDelayNanos = chunkDelayMs * 1_000_000
    }

    /// Number of times the script has been advanced so far.
    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cursor
    }

    /// Snapshot of every history this client was called with — useful
    /// for asserting "the LLM saw the right context" in tests.
    public var observedHistories: [[Message]] {
        lock.lock(); defer { lock.unlock() }
        return _observedHistories
    }

    public func complete(messages: [Message], tools: [ToolDeclaration]) async throws -> Completion {
        let next = try pop(messages)
        return next
    }

    public func stream(messages: [Message], tools: [ToolDeclaration]) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let next = try self.pop(messages)
                    switch next {
                    case .text(let msg):
                        let text = msg.content
                        var i = text.startIndex
                        while i < text.endIndex {
                            let end = text.index(i, offsetBy: self.streamChunkSize, limitedBy: text.endIndex) ?? text.endIndex
                            continuation.yield(.text(String(text[i..<end])))
                            if self.chunkDelayNanos > 0 {
                                try? await Task.sleep(nanoseconds: self.chunkDelayNanos)
                            }
                            i = end
                        }
                    case .toolCalls(let msg):
                        for call in msg.toolCalls {
                            continuation.yield(.toolCallStart(id: call.id, name: call.name))
                            let args = call.arguments
                            var i = args.startIndex
                            while i < args.endIndex {
                                let end = args.index(i, offsetBy: self.streamChunkSize, limitedBy: args.endIndex) ?? args.endIndex
                                continuation.yield(.toolCallArgs(id: call.id, chunk: String(args[i..<end])))
                                if self.chunkDelayNanos > 0 {
                                    try? await Task.sleep(nanoseconds: self.chunkDelayNanos)
                                }
                                i = end
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

    public func close() { /* no-op */ }

    private func pop(_ messages: [Message]) throws -> Completion {
        lock.lock(); defer { lock.unlock() }
        _observedHistories.append(messages)
        guard cursor < script.count else {
            throw NSError(
                domain: "FakeLLMClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "script exhausted after \(cursor) calls — expected \(script.count) entries"]
            )
        }
        let next = script[cursor]
        cursor += 1
        return next
    }
}
