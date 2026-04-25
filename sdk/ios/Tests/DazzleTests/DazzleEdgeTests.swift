// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

@MainActor
final class DazzleEdgeTests: DazzleTestCase {

    func testManifestExposesKnownModels() {
        let g = ModelManifest.gemma4_E2B
        XCTAssertEqual(g.id, "gemma-4-E2B-it")
        XCTAssertEqual(g.filename, "gemma-4-E2B-it.litertlm")
        XCTAssertGreaterThan(g.sizeBytes, 1_000_000_000)
        XCTAssertEqual(g.backend, .liteRTLM)

        XCTAssertGreaterThanOrEqual(ModelManifest.all.count, 3)
        XCTAssertTrue(ModelManifest.all.contains(g))
    }

    func testIsModelReadyWorksAsBooleanProbe() {
        // Don't assert a specific value — other tests / prior runs may
        // have populated the cache. Just exercise the method.
        _ = DazzleEdge.isModelReady(ModelManifest.gemma4_E2B)
    }

    func testChatAgentBootsAndRoundTripsOneTurn() async throws {
        let llm = FakeLLMClient(
            modelId: "fake:edge",
            script: [
                .text(Message(role: .assistant, content: "hello from edge")),
            ]
        )
        let agent = try DazzleEdge.chatAgent(llm: llm, threadId: "edge:test") { cfg in
            cfg.systemPrompt = "You are a test agent."
            cfg.compaction = .none
        }
        defer { agent.close() }

        agent.send("hi")
        try await waitForIdle(agent, timeout: 3.0)

        let msgs = agent.messages
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].text, "hello from edge")
    }

    func testChatAgentAppliesBundleCompactionOverride() async throws {
        var script: [Completion] = []
        for i in 0..<6 {
            script.append(.text(Message(role: .assistant, content: "reply \(i)")))
        }
        let llm = FakeLLMClient(modelId: "fake:edge", script: script)
        let agent = try DazzleEdge.chatAgent(llm: llm, threadId: "edge:compact") { cfg in
            cfg.compaction = .maxTurns(3)
        }
        defer { agent.close() }

        for i in 0..<6 {
            agent.send("turn \(i)")
            try await waitForIdle(agent, timeout: 3.0)
        }
        XCTAssertLessThanOrEqual(agent.messages.count, 3)
    }

    private func waitForIdle(_ agent: ChatAgentImpl, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while agent.status != .idle && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if agent.status != .idle {
            XCTFail("agent did not reach .idle in \(timeout)s — last = \(agent.status)")
        }
    }
}
