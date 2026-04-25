// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Abstract LLM client that an `Agent` drives.
///
/// The SDK does not bundle an LLM runtime — the dev plugs in whichever
/// engine fits their deployment:
///
///   - **Apple Foundation Models** (iOS 18+, on-device)
///   - **LiteRT-LM Swift wrapper** (on-device, cross-platform)
///   - **llama.cpp** wrapper
///   - **OpenAI / Anthropic / Gemini HTTP API** (cloud-augmented)
///   - **`FakeLLMClient`** for unit tests
public protocol LLMClient: AnyObject, Sendable {
    /// Descriptive label for logs / telemetry.
    var modelId: String { get }

    /// Submit the conversation history and return the model's full
    /// response. If `tools` is non-empty the model MAY respond with
    /// tool_calls; the caller executes those and re-invokes
    /// `complete(…)` with the tool results appended.
    func complete(
        messages: [Message],
        tools: [ToolDeclaration]
    ) async throws -> Completion

    /// Stream the response as `Delta` events. Cancel the enclosing
    /// `Task` to abort mid-stream.
    func stream(
        messages: [Message],
        tools: [ToolDeclaration]
    ) -> AsyncThrowingStream<Delta, Error>

    /// Release any native resources. Called automatically on `Agent.close()`.
    func close()
}

public extension LLMClient {
    /// Convenience default for clients that don't need tool declarations.
    func complete(messages: [Message]) async throws -> Completion {
        try await complete(messages: messages, tools: [])
    }

    func stream(messages: [Message]) -> AsyncThrowingStream<Delta, Error> {
        stream(messages: messages, tools: [])
    }
}
