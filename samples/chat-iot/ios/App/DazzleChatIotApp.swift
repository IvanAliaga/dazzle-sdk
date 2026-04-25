// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import SwiftUI

@main
struct DazzleChatIotApp: App {

    init() {
        do {
            try DazzleServer.shared.start(config: DazzleConfig(
                maxMemory:   "128mb",
                persistence: .aof()
            ))
            _ = DazzleServer.shared.waitForReady(timeout: 5.0)
        } catch {
            print("[chat-iot] DazzleServer start failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if isSampleTestMode() {
                SampleTestRunnerView(config: testConfig)
            } else {
                ChatView(
                    title: "chat-iot",
                    buildAgent: buildAgent
                )
            }
        }
    }

    @MainActor
    @Sendable
    private func buildAgent() async throws -> ChatAgentImpl {
        try await IotCorpus.loadIntoDazzle()
        let llm = try await makeLLMClient()
        return buildAgentWithLLM(llm)
    }

    @MainActor
    private func buildAgentWithLLM(_ llm: any LLMClient) -> ChatAgentImpl {
        let tool = RetrieveAnomaliesTool()
        return DazzleServer.shared.client().chatAgent(
            threadId: "chat-iot-default",
            llm:       llm
        ) { cfg in
            cfg.systemPrompt = """
                You are a sensor-data analyst running entirely on-device
                against the user's local Dazzle store. When the user
                asks about temperature, humidity, anomalies, or a
                specific time window, call the retrieve_anomalies tool
                with the minute range (dataset minute 0…2399). Use the
                tool's JSON output to ground your answer — do NOT
                invent numbers. Keep replies concise (2–4 sentences).
                """
            cfg.tools         = [tool]
            cfg.contextWindow = .lastN(20)
            cfg.compaction    = .maxTurns(100)
        }
    }

    // MARK: – Headless SAMPLE_TEST harness

    private var testConfig: SampleTestConfig {
        SampleTestConfig(
            sampleName: "chat-iot",
            // Analyst-style question. The LLM issues
            // retrieve_anomalies(0..800), the tool returns real
            // JSON rows from the on-device SortedSet (including the
            // minute-195 28.5°C spike), and the LLM grounds its
            // final reply in those specific numbers — demonstrating
            // the full tool-loop over a Dazzle dataset.
            llmScript: [
                .toolCalls(Message(
                    role: .assistant, content: "",
                    toolCalls: [ToolCall(
                        id: "c1",
                        name: "retrieve_anomalies",
                        arguments: "{\"min_from\":0,\"min_to\":800}"
                    )]
                )),
                .text(Message(role: .assistant, content:
                    "I found one thermal anomaly in the first 800 minutes: a brief temperature spike to 28.5°C around minute 195, lasting about 3 minutes. Outside that window the sensors stayed stable, averaging 22.1°C with humidity near 48%. The spike pattern is consistent with an interrupted ventilation cycle.")),
            ],
            userInputs: [
                "Run an analysis on the sensor data covering the first 800 minutes of the day. Tell me whether there were any thermal anomalies, when they happened, and how the rest of the window behaved.",
            ],
            prepare: {
                try await IotCorpus.loadIntoDazzle()
            },
            buildAgent: { @MainActor llm in self.buildAgentWithLLM(llm) }
        )
    }
}
