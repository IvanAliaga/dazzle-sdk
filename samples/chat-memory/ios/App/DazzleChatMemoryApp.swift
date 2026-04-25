// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import SwiftUI

@main
struct DazzleChatMemoryApp: App {

    // The Dazzle server is a process-global embedded Valkey instance.
    // Starting it here — once — ties its lifetime to the app. Every
    // ContextStore / VectorIndex / chatAgent call goes through this
    // process. No TCP, no listener — pure JNI pipe.
    init() {
        do {
            try DazzleServer.shared.start(config: DazzleConfig(
                maxMemory:   "128mb",
                persistence: .aof()
            ))
            _ = DazzleServer.shared.waitForReady(timeout: 5.0)
        } catch {
            print("[chat-memory] DazzleServer start failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if isSampleTestMode() {
                SampleTestRunnerView(config: testConfig)
            } else {
                ChatView(
                    title: "chat-memory",
                    buildAgent: buildAgent
                )
            }
        }
    }

    /// The one builder the generic `ChatView` calls. We build the
    /// `ChatAgentImpl` with a fresh `LLMClient` (from the swappable
    /// `LLMAdapter.swift`) and NO tools — this sample is conversation-
    /// only. Every turn is persisted through the agent's memory store.
    @MainActor
    @Sendable
    private func buildAgent() async throws -> ChatAgentImpl {
        let llm = try await makeLLMClient()
        return buildAgentWithLLM(llm)
    }

    @MainActor
    private func buildAgentWithLLM(_ llm: any LLMClient) -> ChatAgentImpl {
        DazzleServer.shared.client().chatAgent(
            threadId: "chat-memory-default",
            llm:       llm
        ) { cfg in
            cfg.systemPrompt = """
                You are Dazzle, a friendly on-device assistant. Keep
                replies short and conversational (1–3 sentences).
                """
            cfg.contextWindow = .lastN(40)
            cfg.compaction    = .maxTurns(200)
        }
    }

    // MARK: – Headless SAMPLE_TEST harness

    private var testConfig: SampleTestConfig {
        SampleTestConfig(
            sampleName: "chat-memory",
            // Two substantive turns demonstrating persistence: the user
            // states identity + project in turn 1, the assistant
            // acknowledges, and turn 2 asks the assistant to recall
            // both — which it can only do because Dazzle restored the
            // prior turn's context on the fresh LLM call.
            llmScript: [
                .text(Message(role: .assistant, content:
                    "Noted, Ivan. Dazzle — embedded DB with HNSW vector search for on-device LLM agents. I'll keep this context.")),
                .text(Message(role: .assistant, content:
                    "Yes — you're Ivan Aliaga, working on Dazzle, an embedded database with HNSW vector search for on-device LLM agents. What would you like to do next?")),
            ],
            userInputs: [
                "Hi, I'm Ivan Aliaga. I'm building Dazzle — an embedded database with HNSW vector search for on-device LLM agents. Please remember this.",
                "Do you remember who I am and what I'm working on?",
            ],
            prepare: { /* no-op; memory sample has no dataset */ },
            buildAgent: { @MainActor llm in self.buildAgentWithLLM(llm) }
        )
    }
}
