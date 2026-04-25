// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import SwiftUI

@main
struct DazzleChatKbApp: App {

    init() {
        do {
            try DazzleServer.shared.start(config: DazzleConfig(
                maxMemory:   "128mb",
                persistence: .aof(),
                modules:     [.vectorSearch]
            ))
            _ = DazzleServer.shared.waitForReady(timeout: 5.0)
        } catch {
            print("[chat-kb] DazzleServer start failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if isSampleTestMode() {
                SampleTestRunnerView(config: testConfig)
            } else {
                ChatView(
                    title: "chat-kb",
                    buildAgent: buildAgent
                )
            }
        }
    }

    @MainActor
    @Sendable
    private func buildAgent() async throws -> ChatAgentImpl {
        try await KbCorpus.loadIntoDazzle()
        let llm = try await makeLLMClient()
        return buildAgentWithLLM(llm)
    }

    @MainActor
    private func buildAgentWithLLM(_ llm: any LLMClient) -> ChatAgentImpl {
        let tool = SearchKbTool()
        return DazzleServer.shared.client().chatAgent(
            threadId: "chat-kb-default",
            llm:       llm
        ) { cfg in
            cfg.systemPrompt = """
                You are a Dazzle-SDK support assistant running entirely
                on-device. For ANY question about Dazzle, HNSW,
                sqlite-vec, sqlite-vector-ai, the four LLM adapters, or
                the benchmarks, call search_kb(query, k=5) first and
                ground your answer in the returned FAQ rows. If the
                question is clearly not about Dazzle, answer directly.
                Keep replies concise (2–4 sentences).
                """
            cfg.tools         = [tool]
            cfg.contextWindow = .lastN(20)
            cfg.compaction    = .maxTurns(100)
        }
    }

    // MARK: – Headless SAMPLE_TEST harness

    private var testConfig: SampleTestConfig {
        SampleTestConfig(
            sampleName: "chat-kb",
            // Technical question about the SDK itself. LLM issues a
            // search_kb() query, the HNSW_SQ8 index returns FAQ rows
            // with the Dazzle vs sqlite-vec benchmark numbers, and
            // the final reply grounds the comparison in those
            // concrete figures.
            llmScript: [
                .toolCalls(Message(
                    role: .assistant, content: "",
                    toolCalls: [ToolCall(
                        id: "c1",
                        name: "search_kb",
                        arguments: "{\"query\":\"HNSW_SQ8 vs sqlite-vec mobile latency memory benchmark\",\"k\":5}"
                    )]
                )),
                .text(Message(role: .assistant, content:
                    "Dazzle uses HNSW_SQ8 — a proximity-graph index with 8-bit scalar quantization. On a Moto G35 benchmark with 10k × 384-d vectors, Dazzle runs queries in about 2.3 ms versus ~180 ms for sqlite-vec, which does a linear brute-force scan. The quantized index is also around 4× smaller than F32 — roughly 40 MB vs 160 MB for the same corpus — which matters on mid-tier devices where RAM is tight.")),
            ],
            userInputs: [
                "Explain how Dazzle handles vector search on mobile and how it compares to sqlite-vec in terms of query latency and memory footprint.",
            ],
            prepare: {
                try await KbCorpus.loadIntoDazzle()
            },
            buildAgent: { @MainActor llm in self.buildAgentWithLLM(llm) }
        )
    }
}
