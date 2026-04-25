// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

/// End-to-end agent tests driven by a scripted `FakeLLMClient`. Mirrors
/// the Android ChatAgentInstrumentedTest suite.
@MainActor
final class ChatAgentTests: DazzleTestCase {

    func testPlainTextResponseCommitsAssistantTurn() async throws {
        let llm = FakeLLMClient(
            modelId: "test",
            script: [
                .text(Message(role: .assistant, content: "Hola, ¿cómo estás?"))
            ]
        )
        let agent = dazzle.chatAgent(threadId: "test:plain", llm: llm) { cfg in
            cfg.systemPrompt = "You are a tester."
            cfg.compaction = .none
        }
        defer { agent.close() }

        _ = try DazzleServer.shared.client().flushDb()
        agent.send("Hola")

        try await waitForIdle(agent, timeout: 3.0)

        let msgs = agent.messages
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[0].text, "Hola")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].text, "Hola, ¿cómo estás?")
        XCTAssertEqual(llm.callCount, 1)
    }

    func testToolCallLoopInvokesToolAndCommitsFinalText() async throws {
        struct AddArgs: Sendable { let a: Int; let b: Int }

        struct AddTool: Tool {
            typealias Args = AddArgs
            typealias Ret = Int
            let name = "math.add"
            let description = "Add two integers"
            let argsSchema: JsonSchema = jsonSchemaObject {
                $0.property("a", type: "integer", required: true)
                $0.property("b", type: "integer", required: true)
            }
            func invoke(args: AddArgs, ctx: ToolContext) async throws -> Int {
                args.a + args.b
            }
            func argsFromJson(_ raw: String) throws -> AddArgs {
                func pick(_ k: String) -> Int {
                    let pattern = "\"\(k)\"\\s*:\\s*(-?\\d+)"
                    if let r = try? NSRegularExpression(pattern: pattern),
                       let m = r.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                       let range = Range(m.range(at: 1), in: raw) {
                        return Int(raw[range]) ?? 0
                    }
                    return 0
                }
                return AddArgs(a: pick("a"), b: pick("b"))
            }
            func returnToJson(_ value: Int) -> String { String(value) }
        }

        let llm = FakeLLMClient(
            modelId: "test",
            script: [
                .toolCalls(Message(
                    role: .assistant, content: "",
                    toolCalls: [ToolCall(id: "c1", name: "math.add", arguments: "{\"a\":3,\"b\":4}")]
                )),
                .text(Message(role: .assistant, content: "The sum is 7.")),
            ]
        )
        let agent = dazzle.chatAgent(threadId: "test:tool", llm: llm) { cfg in
            cfg.tools.append(AddTool())
            cfg.compaction = .none
        }
        defer { agent.close() }

        _ = try DazzleServer.shared.client().flushDb()
        agent.send("What's 3 + 4?")
        try await waitForIdle(agent, timeout: 3.0)

        let msgs = agent.messages
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].toolCalls.count, 1)
        XCTAssertEqual(msgs[1].toolCalls[0].name, "math.add")
        XCTAssertEqual(msgs[2].role, .tool)
        XCTAssertEqual(msgs[2].text, "7")
        XCTAssertEqual(msgs[2].toolCallId, "c1")
        XCTAssertEqual(msgs[3].role, .assistant)
        XCTAssertEqual(msgs[3].text, "The sum is 7.")
        XCTAssertEqual(llm.callCount, 2)
    }

    func testCompactionMaxTurnsBoundsStorage() async throws {
        var scripted: [Completion] = []
        for i in 0..<10 {
            scripted.append(.text(Message(role: .assistant, content: "ok \(i)")))
        }
        let llm = FakeLLMClient(modelId: "test", script: scripted)
        let agent = dazzle.chatAgent(threadId: "test:compact", llm: llm) { cfg in
            cfg.compaction = .maxTurns(4)
        }
        defer { agent.close() }

        _ = try DazzleServer.shared.client().flushDb()
        for i in 0..<10 {
            agent.send("turn \(i)")
            try await waitForIdle(agent, timeout: 3.0)
        }

        XCTAssertLessThanOrEqual(
            agent.messages.count, 4,
            "messages should be capped at 4, got \(agent.messages.count)"
        )
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private func waitForIdle(_ agent: ChatAgentImpl, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while agent.status != .idle && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
        if agent.status != .idle {
            XCTFail("agent did not reach .idle within \(timeout)s — last status = \(agent.status)")
        }
    }
}
