// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// Shared SwiftUI chat screen. Every Dazzle sample references this file
// via the per-sample `project.yml` so the chat UX is identical across
// chat-memory, chat-iot, and chat-kb.

import SwiftUI

/// Generic chat screen that drives any `ChatAgentImpl`. The sample only
/// needs to build the agent (with its own tools / system prompt) and
/// pass it in; this view handles scroll, input, streaming dots, tool
/// call pills, and error surfacing.
@MainActor
public struct ChatView: View {
    @State private var agent: ChatAgentImpl?
    @State private var input: String = ""
    @State private var errorMessage: String?

    /// Human-readable title shown in the nav bar.
    public let title: String

    /// Builds the `ChatAgentImpl`. Called once on first appearance; the
    /// sample injects its own tools + system prompt inside.
    public let buildAgent: @MainActor @Sendable () async throws -> ChatAgentImpl

    public init(
        title: String,
        buildAgent: @escaping @MainActor @Sendable () async throws -> ChatAgentImpl
    ) {
        self.title = title
        self.buildAgent = buildAgent
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let agent = agent {
                    messagesList(agent: agent)
                    inputBar(agent: agent)
                } else if let err = errorMessage {
                    errorBanner(err)
                } else {
                    loadingStub
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await bootstrapAgent() }
    }

    // MARK: – Subviews

    @ViewBuilder
    private func messagesList(agent: ChatAgentImpl) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(agent.messages, id: \.id) { turn in
                        MessageBubble(turn: turn).id(turn.id)
                    }
                    if let streaming = agent.streaming {
                        StreamingBubble(streaming: streaming).id("__streaming__")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: agent.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if let last = agent.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: agent.streaming?.text) { _, _ in
                proxy.scrollTo("__streaming__", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func inputBar(agent: ChatAgentImpl) -> some View {
        HStack(spacing: 8) {
            TextField("Ask Dazzle…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(agent.status != .idle)
                .onSubmit { send(agent: agent) }

            Button {
                send(agent: agent)
            } label: {
                Image(systemName: agent.status == .idle
                      ? "arrow.up.circle.fill"
                      : "stop.circle.fill")
                    .font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty
                      && agent.status == .idle)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var loadingStub: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading model + booting Dazzle…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't start", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: – Actions

    private func bootstrapAgent() async {
        guard agent == nil, errorMessage == nil else { return }
        do {
            let built = try await buildAgent()
            self.agent = built
        } catch {
            self.errorMessage = String(describing: error)
        }
    }

    private func send(agent: ChatAgentImpl) {
        if agent.status != .idle {
            agent.cancel()
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        agent.send(text)
    }
}

// MARK: – Bubbles

private struct MessageBubble: View {
    let turn: ChatTurn

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if turn.role == .tool {
                    toolLabel
                }
                Text(turn.text.isEmpty ? "…" : turn.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(background)
                    .foregroundStyle(foreground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if turn.role != .user { Spacer(minLength: 40) }
        }
    }

    private var toolLabel: some View {
        Text("tool reply")
            .font(.caption2).bold()
            .foregroundStyle(.secondary)
    }

    private var background: Color {
        switch turn.role {
        case .user:      return .accentColor
        case .assistant: return Color(.systemGray6)
        case .tool:      return Color(.systemGray5)
        case .system:    return Color(.systemYellow).opacity(0.25)
        }
    }

    private var foreground: Color {
        turn.role == .user ? .white : .primary
    }
}

private struct StreamingBubble: View {
    let streaming: StreamingMessage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let tool = streaming.activeTool {
                    Text("calling \(tool)…")
                        .font(.caption2).bold()
                        .foregroundStyle(.secondary)
                }
                Text(streaming.text.isEmpty ? "▍" : streaming.text + "▍")
                    .font(.callout)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Spacer(minLength: 40)
        }
    }
}
