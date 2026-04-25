// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Demo-only `LLMClient` that echoes the user's last message back with
/// a short prefix. Streams token-by-token with a small delay so the UI
/// shows a believable "typing" animation.
///
/// Swap this for `LiteRtLmClient` (DazzleLiteRTLM) or any cloud API
/// adapter to drive the same `ChatView` with a real model — the only
/// thing the UI layer knows is the `Agent` protocol.
final class EchoLLMClient: LLMClient, @unchecked Sendable {

    let modelId: String = "demo:echo"
    private let chunkDelayMs: UInt64

    init(chunkDelayMs: UInt64 = 25) {
        self.chunkDelayMs = chunkDelayMs
    }

    func complete(messages: [Message], tools: [ToolDeclaration]) async throws -> Completion {
        let reply = Self.generateReply(messages)
        return .text(Message(role: .assistant, content: reply))
    }

    func stream(messages: [Message], tools: [ToolDeclaration]) -> AsyncThrowingStream<Delta, Error> {
        let reply = Self.generateReply(messages)
        let delay = chunkDelayMs * 1_000_000
        return AsyncThrowingStream { continuation in
            let task = Task {
                for ch in reply {
                    continuation.yield(.text(String(ch)))
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
                continuation.yield(.end)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() {}

    // MARK: – Helpers

    private static func generateReply(_ messages: [Message]) -> String {
        let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""
        let turnCount = messages.filter { $0.role == .user }.count
        if lastUser.isEmpty {
            return "Hi! I'm the Dazzle demo echo. Try asking me something."
        }
        return "You said: \"\(lastUser)\". This conversation has \(turnCount) turn\(turnCount == 1 ? "" : "s")."
    }
}
