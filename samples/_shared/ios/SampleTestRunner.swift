// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// Headless test harness shared across the three samples. Each sample's
// app file detects `SAMPLE_TEST=1` in the environment and, if set,
// swaps the normal `ChatView` for `SampleTestRunnerView`, which drives
// a scripted end-to-end flow through the full DazzleEdge + ChatAgent
// pipeline AND renders the conversation on-screen so a human watching
// the device sees the scripted run play out. It then writes a JSON
// report to Documents and exits.
//
// The harness uses `FakeLLMClient` so the test runs without a 1 GB
// GGUF download — it validates what the sample actually owns (Dazzle
// boot, ChatAgent wiring, tool loop, persistence). Real-LLM
// integration is covered by separate instrumented tests in the SDK.

import SwiftUI
import Foundation

/// Inputs the sample passes in when it detects test mode.
public struct SampleTestConfig: Sendable {
    public let sampleName: String
    public let llmScript: [Completion]
    public let userInputs: [String]
    /// Sample-specific pre-send hook — e.g. load the IoT dataset or
    /// the KB corpus into Dazzle before the test sends any user turn.
    public let prepare: @MainActor @Sendable () async throws -> Void
    /// Sample-specific agent builder. Receives the FakeLLMClient the
    /// harness constructed; the closure wires the same tools + system
    /// prompt the production app uses.
    public let buildAgent: @MainActor @Sendable (_ llm: any LLMClient) async throws -> ChatAgentImpl
    /// Pause between each user input so turns land one at a time on
    /// the screen instead of all at once. Default 1.2 s.
    public let delayBetweenTurns: TimeInterval
    /// Pause after the final assistant reply, before the harness
    /// writes the report + exits. Long enough for a human viewer to
    /// read the last message. Default 5 s.
    public let postRunDisplay: TimeInterval

    public init(
        sampleName: String,
        llmScript: [Completion],
        userInputs: [String],
        prepare: @escaping @MainActor @Sendable () async throws -> Void,
        buildAgent: @escaping @MainActor @Sendable (_ llm: any LLMClient) async throws -> ChatAgentImpl,
        delayBetweenTurns: TimeInterval = 1.2,
        postRunDisplay: TimeInterval = 5.0
    ) {
        self.sampleName = sampleName
        self.llmScript = llmScript
        self.userInputs = userInputs
        self.prepare = prepare
        self.buildAgent = buildAgent
        self.delayBetweenTurns = delayBetweenTurns
        self.postRunDisplay = postRunDisplay
    }
}

/// SwiftUI view the app roots when `SAMPLE_TEST=1` is in the env. It
/// owns a `Task` that runs the scripted flow AND renders the
/// conversation live, then writes the report and exits the process
/// with `exit(0)` (pass) or `exit(1)` (fail).
public struct SampleTestRunnerView: View {
    public let config: SampleTestConfig
    @State private var agent: ChatAgentImpl?
    @State private var phase: Phase = .preparing
    @State private var detail: String? = nil
    @State private var errorMessage: String? = nil

    enum Phase { case preparing, running, completed, failed }

    public init(config: SampleTestConfig) { self.config = config }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                if let agent = agent {
                    messagesList(agent: agent)
                } else if let err = errorMessage {
                    errorView(err)
                } else {
                    ProgressView()
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("\(config.sampleName) · test")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(priority: .userInitiated) { await runTest() }
    }

    // MARK: – Banner

    @ViewBuilder private var banner: some View {
        let (bg, text, systemImage) = bannerStyle(phase)
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.white)
            Text(detail == nil ? text : "\(text)  —  \(detail!)")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bg)
    }

    private func bannerStyle(_ p: Phase) -> (Color, String, String) {
        switch p {
        case .preparing:
            return (Color(red: 0.12, green: 0.23, blue: 0.54),
                    "DEV SMOKE · scripted (no real LLM) · preparing",
                    "hourglass")
        case .running:
            return (Color(red: 0.12, green: 0.23, blue: 0.54),
                    "DEV SMOKE · scripted (no real LLM) · tap icon for Qwen",
                    "play.fill")
        case .completed:
            return (Color(red: 0.09, green: 0.40, blue: 0.20),
                    "DEV SMOKE · complete · app icon = real Qwen",
                    "checkmark.circle.fill")
        case .failed:
            return (Color(red: 0.50, green: 0.11, blue: 0.11),
                    "DEV SMOKE · failed",
                    "xmark.octagon.fill")
        }
    }

    // MARK: – Messages list (reactive)

    @ViewBuilder
    private func messagesList(agent: ChatAgentImpl) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    // Hide raw tool-JSON bubbles and empty assistant
                    // envelopes — they're internal LLM context, not
                    // user-facing messages. Stand in for each tool
                    // round-trip with a compact "called <tool>" pill.
                    let msgs = agent.messages
                    ForEach(Array(msgs.enumerated()), id: \.offset) { i, turn in
                        if turn.role == .tool {
                            EmptyView()
                        } else if turn.role == .assistant && turn.text.isEmpty {
                            let nextTool = msgs[(i + 1)..<msgs.count]
                                .first(where: { $0.role == .tool })
                            if nextTool != nil {
                                toolPill(name: turn.toolCalls.first?.name ?? "tool")
                                    .id(turn.id)
                            }
                        } else {
                            bubble(for: turn).id(turn.id)
                        }
                    }
                    if let s = agent.streaming {
                        bubble(streaming: s.text, tool: s.activeTool)
                    }
                }
                .padding(12)
            }
            .onChange(of: agent.messages.count) { _, _ in
                if let last = agent.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func toolPill(name: String) -> some View {
        HStack {
            Text("⚙ called \(name)")
                .font(.caption)
                .italic()
                .foregroundColor(Color(red: 0.50, green: 0.39, blue: 0.00))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(red: 1.00, green: 0.96, blue: 0.83))
                .cornerRadius(10)
            Spacer()
        }
    }

    @ViewBuilder
    private func bubble(for turn: ChatTurn) -> some View {
        let (bg, fg, label): (Color, Color, String) = {
            switch turn.role {
            case .user:      return (Color.blue,  Color.white, "you")
            case .assistant:
                let callSummary = turn.toolCalls.first.map { "assistant · calls \($0.name)" }
                return (Color(white: 0.92), Color.black,
                        callSummary ?? "assistant")
            case .tool:
                let id = turn.toolCallId ?? "?"
                return (Color(white: 0.80), Color.black, "tool · \(id)")
            case .system:    return (Color(white: 0.60), Color.white, "system")
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.gray)
            Text(turn.text)
                .foregroundColor(fg)
                .padding(8)
                .background(bg)
                .cornerRadius(10)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity,
               alignment: turn.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func bubble(streaming text: String, tool: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tool != nil ? "tool · \(tool!)" : "assistant · streaming")
                .font(.caption2).foregroundColor(.gray)
            Text(text.isEmpty ? "…" : text)
                .padding(8)
                .background(Color(white: 0.88))
                .cornerRadius(10)
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
            Text("Couldn't start").font(.headline)
            Text(message).font(.caption).multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Test driver

    @MainActor
    private func runTest() async {
        let start = Date()
        do {
            phase = .preparing
            try await config.prepare()

            // Real LLM path when DAZZLE_REAL_LLM=1. Lets the smoke
            // exercise an actual on-device or remote LLM (HF, OpenAI,
            // LlamaCpp, …) without forking the harness.
            let useReal = ProcessInfo.processInfo
                .environment["DAZZLE_REAL_LLM"] == "1"
            let fake = FakeLLMClient(script: config.llmScript)
            let llm: any LLMClient
            if useReal {
                NSLog("[SampleTestRunner] DAZZLE_REAL_LLM=1 → using LLMAdapter")
                llm = try await makeLLMClient()
            } else {
                llm = fake
            }
            let a = try await config.buildAgent(llm)
            agent = a

            try? await Task.sleep(nanoseconds: 400_000_000)
            phase = .running

            // Real LLMs (esp. cloud routers) take 5–60 s/turn.
            let perTurnTimeout: TimeInterval = useReal ? 90 : 30
            for (i, input) in config.userInputs.enumerated() {
                if i > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(config.delayBetweenTurns * 1_000_000_000))
                }
                a.send(input)
                let deadline = Date().addingTimeInterval(perTurnTimeout)
                while a.status != .idle {
                    if Date() > deadline {
                        throw NSError(domain: "SampleTest", code: 1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "turn \(i + 1) timed out after \(Int(perTurnTimeout)) s"])
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            let toolTurns = a.messages.filter { $0.role == .tool }
            let assistantTurns = a.messages.filter { $0.role == .assistant }
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

            phase = .completed
            detail = "\(a.messages.count) turns · \(elapsedMs) ms"

            // Hold the final frame so a human viewer can read the last reply.
            try? await Task.sleep(
                nanoseconds: UInt64(config.postRunDisplay * 1_000_000_000))

            let report = TestReport(
                sampleName: config.sampleName,
                elapsedMs:  Int(Date().timeIntervalSince(start) * 1000),
                turnCount:  a.messages.count,
                userTurns:  a.messages.filter { $0.role == .user }.count,
                assistantTurns: assistantTurns.count,
                toolTurns:  toolTurns.count,
                llmCallCount: fake.callCount,
                lastAssistantText: assistantTurns.last?.text ?? "",
                lastToolText: toolTurns.last?.text ?? "",
                status:     "pass",
                error:      nil
            )
            writeReport(report)
            writeMarker(ok: true, message: "sample_test_\(config.sampleName)")
            try? await Task.sleep(nanoseconds: 200_000_000)
            exit(0)
        } catch {
            phase = .failed
            detail = "\(error)"
            errorMessage = "\(error)"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let report = TestReport(
                sampleName: config.sampleName,
                elapsedMs:  elapsedMs,
                turnCount:  0, userTurns: 0, assistantTurns: 0, toolTurns: 0,
                llmCallCount: 0,
                lastAssistantText: "", lastToolText: "",
                status: "fail",
                error: String(describing: error)
            )
            writeReport(report)
            writeMarker(ok: false, message: "sample_test_\(config.sampleName)")
            try? await Task.sleep(nanoseconds: 200_000_000)
            exit(1)
        }
    }

    private func writeReport(_ r: TestReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(r) else { return }
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("sample_test_\(r.sampleName).json")
        try? data.write(to: url)
    }

    private func writeMarker(ok: Bool, message: String) {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("experiment_ios_complete.marker")
        let line = "\(Int(Date().timeIntervalSince1970 * 1000)) "
                 + "\(ok ? "ok" : "error") \(message)\n"
        try? line.data(using: .utf8)?.write(to: url)
    }
}

public struct TestReport: Codable {
    public let sampleName: String
    public let elapsedMs:  Int
    public let turnCount:  Int
    public let userTurns:  Int
    public let assistantTurns: Int
    public let toolTurns:  Int
    public let llmCallCount: Int
    public let lastAssistantText: String
    public let lastToolText: String
    public let status:     String  // "pass" | "fail"
    public let error:      String?
}

/// Helper every sample's App struct can call. Returns true when
/// `SAMPLE_TEST=1` is set in the process environment.
public func isSampleTestMode() -> Bool {
    ProcessInfo.processInfo.environment["SAMPLE_TEST"] == "1"
}
