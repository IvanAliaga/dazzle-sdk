// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// One-liner on-ramp to an on-device agent — the Layer 3 bundle.
///
/// Composes Layer 1 (embedded Valkey), Layer 2 (ContextStore + Agent)
/// and a pinned model manifest into a single entry point. Mirror of
/// the Android `DazzleEdge`.
public enum DazzleEdge {

    /// Ensure the given model file is present on disk. Lazy download
    /// + resume + SHA-256 verification. Returns the absolute URL of
    /// the verified file.
    public static func ensureModel(
        _ model: ModelManifest.Entry = ModelManifest.gemma4_E2B,
        onProgress: @escaping @Sendable (_ loaded: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        try await ModelDownloader.ensure(model, onProgress: onProgress)
    }

    /// Non-network check — returns the cached URL if a verified copy
    /// already exists on disk.
    public static func isModelReady(_ model: ModelManifest.Entry) -> URL? {
        ModelDownloader.cached(model)
    }

    /// Bootstrap a chat agent with Dazzle's recommended defaults.
    /// See the Android doc comment in DazzleEdge.kt for the full contract.
    @MainActor
    public static func chatAgent(
        llm: any LLMClient,
        threadId: String = "default",
        configure: (ChatAgentBundle) -> Void = { _ in }
    ) throws -> ChatAgentImpl {
        let bundle = ChatAgentBundle()
        configure(bundle)
        try Self.ensureServerStarted(
            execution: bundle.execution,
            vectorSearch: bundle.vectorSearch
        )
        let client = DazzleServer.shared.client()
        let agent = client.chatAgent(threadId: threadId, llm: llm) { cfg in
            cfg.systemPrompt = bundle.systemPrompt
            cfg.tools = bundle.tools
            cfg.contextWindow = bundle.contextWindow
            cfg.compaction = bundle.compaction
            cfg.execution = bundle.execution
            cfg.maxToolIterations = bundle.maxToolIterations
        }
        return agent
    }

    /// Stop the shared server. Call on app teardown.
    public static func shutdown() {
        DazzleServer.shared.stop()
    }

    // ── Internals ────────────────────────────────────────────────────

    private static func ensureServerStarted(
        execution: ExecutionPolicy,
        vectorSearch: Bool
    ) throws {
        if DazzleServer.shared.isRunning { return }
        var modules: Set<DazzleModule> = [.lua]
        if vectorSearch { modules.insert(.vectorSearch) }
        _ = try DazzleServer.shared.start(config: DazzleConfig(
            persistence: .none,
            modules: modules,
            execution: execution
        ))
    }
}

/// Mutable bundle config. Mirrors Android `ChatAgentBundle`.
public final class ChatAgentBundle: @unchecked Sendable {
    public var systemPrompt: String = "You are a helpful on-device AI assistant."
    public var tools: [any ErasedTool] = []
    public var contextWindow: ContextWindow = .default
    public var compaction: CompactionPolicy = .default
    public var execution: ExecutionPolicy = .balanced
    public var maxToolIterations: Int = 8
    /// If true, boots the server with the valkey-search module so any
    /// ContextStore the agent creates can use `semanticSearch`.
    public var vectorSearch: Bool = false

    public init() {}
}
