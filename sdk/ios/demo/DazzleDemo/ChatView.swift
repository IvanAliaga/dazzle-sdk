// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import SwiftUI

/// Live chat screen wired to a `DazzleEdge.chatAgent` running against
/// `EchoLLMClient`. End-to-end this exercises:
///
/// 1. Layer 1: the embedded Valkey server booted by `DazzleEdge`
/// 2. Layer 2: `ContextStore<ChatTurn>` persisting `messages`
/// 3. Layer 3: `DazzleEdge.chatAgent` as the one-liner entry point
/// 4. `ChatAgentImpl` @Observable state driving the SwiftUI bindings
///
/// Swap `EchoLLMClient` for `LiteRtLmClient` from the `DazzleLiteRTLM`
/// opt-in module to get real Gemma / Llama / Qwen responses — the rest
/// of this file stays unchanged.
struct ChatView: View {
    @State private var agent: ChatAgentImpl?
    @State private var errorMsg: String?
    @State private var input: String = ""
    /// Thread id for persistent memory. Using a fixed value per demo
    /// session keeps the conversation across view dismissals; change
    /// this to a date-based token if you want fresh history per open.
    private let threadId = "demo-default"

    var body: some View {
        ZStack {
            if let agent {
                chatBody(agent: agent)
            } else if let errorMsg {
                VStack(spacing: 12) {
                    Text("Couldn't start chat")
                        .font(.headline)
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            } else {
                ProgressView("Starting Dazzle chat…")
            }
        }
        .navigationTitle("Chat")
        .task {
            await setupAgent()
        }
    }

    // MARK: – Chat body

    @ViewBuilder
    private func chatBody(agent: ChatAgentImpl) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(agent.messages) { turn in
                            MessageRow(turn: turn)
                        }
                        if let streaming = agent.streaming {
                            StreamingRow(text: streaming.text, activeTool: streaming.activeTool)
                                .id("streamingBubble")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: agent.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(anchorId(for: agent), anchor: .bottom) }
                }
                .onChange(of: agent.streaming?.text) { _, _ in
                    proxy.scrollTo("streamingBubble", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .disabled(agent.status != .idle)
                    .onSubmit { submit(agent: agent) }
                Button {
                    submit(agent: agent)
                } label: {
                    if agent.status == .idle {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    } else {
                        ProgressView()
                    }
                }
                .disabled(agent.status != .idle || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                statusBadge(agent.status)
            }
        }
    }

    private func anchorId(for agent: ChatAgentImpl) -> String {
        agent.messages.last?.id ?? "streamingBubble"
    }

    private func submit(agent: ChatAgentImpl) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, agent.status == .idle else { return }
        input = ""
        agent.send(trimmed)
    }

    // MARK: – Setup

    @MainActor
    private func setupAgent() async {
        if agent != nil { return }
        do {
            let llm = EchoLLMClient()
            let built = try DazzleEdge.chatAgent(llm: llm, threadId: threadId) { cfg in
                cfg.systemPrompt = "You are the Dazzle on-device chat demo."
            }
            agent = built
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    // MARK: – Status badge

    @ViewBuilder
    private func statusBadge(_ status: AgentStatus) -> some View {
        switch status {
        case .idle:
            Label("Idle", systemImage: "checkmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        case .thinking, .streaming:
            ProgressView().scaleEffect(0.7)
        case .toolCalling:
            Label("Tool", systemImage: "wrench.and.screwdriver")
                .labelStyle(.iconOnly)
                .foregroundStyle(.blue)
        case .error:
            Label("Error", systemImage: "exclamationmark.triangle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
        }
    }
}

// MARK: – Row views

/// A single persisted turn in the chat. System turns are hidden so the
/// screen stays focused on the user ↔ assistant exchange.
private struct MessageRow: View {
    let turn: ChatTurn

    var body: some View {
        if turn.role == .system { EmptyView() }
        else {
            HStack {
                if turn.role == .user { Spacer(minLength: 40) }
                bubble
                if turn.role != .user { Spacer(minLength: 40) }
            }
        }
    }

    private var bubble: some View {
        let isUser = turn.role == .user
        return Text(turn.text.isEmpty ? "(no content)" : turn.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Typing bubble for the in-flight assistant response. Shows the
/// current activeTool name when the agent is running a tool call so
/// the user sees the reason for the pause.
private struct StreamingRow: View {
    let text: String
    let activeTool: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let activeTool {
                    Label(activeTool, systemImage: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(text.isEmpty ? "…" : text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Spacer(minLength: 40)
        }
    }
}

#Preview {
    NavigationStack { ChatView() }
}
