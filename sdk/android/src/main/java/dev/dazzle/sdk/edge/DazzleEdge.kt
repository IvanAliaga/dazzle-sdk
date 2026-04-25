// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

import android.content.Context
import dev.dazzle.sdk.Agent
import dev.dazzle.sdk.CompactionPolicy
import dev.dazzle.sdk.ContextWindow
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.ExecutionPolicy
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Tool
import dev.dazzle.sdk.chatAgent
import java.io.File

/**
 * One-liner on-ramp to an on-device agent — the Layer 3 bundle.
 *
 * Composes Layer 1 (embedded Valkey), Layer 2 (ContextStore + Agent)
 * and a pinned model manifest into a single entry point. The typical
 * consumer path:
 *
 * ```kotlin
 * // 1. Ensure the default model weights are on disk (lazy download)
 * val modelFile = DazzleEdge.ensureModel(context) { loaded, total ->
 *     progressBar.update(loaded, total)
 * }
 *
 * // 2. Instantiate your preferred LLMClient against the file
 * val llm = MyLiteRtLmClient(modelFile)  // user-provided for now
 *
 * // 3. Build the agent with sensible defaults
 * val agent = DazzleEdge.chatAgent(context, llm = llm) {
 *     systemPrompt = "You are a helpful edge assistant."
 *     tools += weatherTool
 * }
 *
 * agent.send("What's the weather?")
 * ```
 *
 * **Design note:** DazzleEdge does NOT bundle a concrete LLM runtime.
 * The LiteRT-LM adapter lives in a separate module consumers opt into;
 * shipping it here would force every Dazzle AAR consumer to pull the
 * ~50 MB LiteRT-LM runtime even if they use a cloud API or their own
 * inference engine.
 */
object DazzleEdge {

    /**
     * Ensure the given model file is present on disk, downloading it
     * lazily (with resume + SHA-256 verification) if not. Safe to call
     * on every app start; returns instantly when the cache already
     * holds a verified copy.
     *
     * Call from [Dispatchers.IO] or any background thread — blocks the
     * caller for the duration of the transfer when a download is
     * needed. Typical Gemma 4 E2B download on an LTE connection takes
     * 3-8 minutes.
     *
     * @param model manifest entry. Defaults to Gemma 4 E2B IT (2.41 GB).
     * @param onProgress `(loaded, total)` fires every ~1 % or every 4 MB.
     */
    @JvmOverloads
    fun ensureModel(
        context: Context,
        model: ModelManifest.Entry = ModelManifest.gemma4_E2B,
        onProgress: (loaded: Long, total: Long) -> Unit = { _, _ -> },
    ): File = ModelDownloader.ensure(context, model, onProgress)

    /**
     * Shortcut: report whether the model is already downloaded + verified
     * without hitting the network. Useful for UIs that show a
     * "download model" button only when needed.
     */
    fun isModelReady(context: Context, model: ModelManifest.Entry): Boolean =
        ModelDownloader.cached(context, model) != null

    /**
     * Bootstrap a chat agent with Dazzle's recommended defaults.
     *
     * Boots [DazzleServer] (if not already running) with a config tuned
     * for a single-LLM workload, wires a `ContextStore<ChatTurn>` as
     * persistent memory under `agent:<threadId>:memory`, and returns a
     * ready-to-go [Agent] bound to [llm].
     *
     * @param llm the LLM runtime to drive this agent. Bring your own
     *        adapter (LiteRT-LM, llama.cpp, HTTP proxy, …) or use the
     *        official LiteRtLmClient when that module ships.
     * @param threadId stable identifier — same id = same memory across
     *        process restarts.
     */
    fun chatAgent(
        context: Context,
        llm: LLMClient,
        threadId: String = "default",
        build: ChatAgentBundle.() -> Unit = {},
    ): Agent {
        val bundle = ChatAgentBundle().apply(build)
        ensureServerStarted(context, bundle.execution, bundle.vectorSearch)
        return DazzleServer.client().chatAgent(threadId = threadId, llm = llm) {
            systemPrompt = bundle.systemPrompt
            tools.addAll(bundle.tools)
            contextWindow = bundle.contextWindow
            compaction = bundle.compaction
            execution = bundle.execution
            maxToolIterations = bundle.maxToolIterations
        }
    }

    /**
     * Stop the shared server. Call once on app teardown — agents and
     * LLM clients built through this bundle remain usable across a
     * process lifetime and only the shutdown here releases the server.
     */
    fun shutdown() { DazzleServer.stop() }

    // ── Internals ────────────────────────────────────────────────────

    private fun ensureServerStarted(
        context: Context,
        execution: ExecutionPolicy,
        vectorSearch: Boolean,
    ) {
        if (DazzleServer.isRunning()) return
        val modules: Set<DazzleModule> =
            if (vectorSearch) setOf(DazzleModule.VectorSearch) else emptySet()
        DazzleServer.start(
            context,
            DazzleConfig(
                execution = execution,
                modules = modules,
                allowPortFallback = true,
            ),
        )
    }
}

/**
 * Mutable configuration for [DazzleEdge.chatAgent]. Mirrors the Layer 2
 * ChatAgent builder but keeps the Layer 3 surface minimal: common knobs,
 * sensible defaults, no need to reach for `ContextStore` / `DazzleServer`
 * directly.
 */
class ChatAgentBundle {
    /** Free-form system prompt. Supports `{placeholder}` substitution
     *  via [Agent] / ChatAgentImpl when `systemPromptVars` is set —
     *  the Layer 3 bundle doesn't expose that knob yet; use Layer 2
     *  directly if you need dynamic variables. */
    var systemPrompt: String = "You are a helpful on-device AI assistant."

    val tools: MutableList<Tool<*, *>> = mutableListOf()

    /** Controls what goes INTO each LLM call. Default = LastN(20). */
    var contextWindow: ContextWindow = ContextWindow.default

    /** Controls what stays in persistent memory long-term. Default =
     *  MaxTurns(200). */
    var compaction: CompactionPolicy = CompactionPolicy.default

    /** Threading + parallelism. Default = balanced (auto-sized read pool). */
    var execution: ExecutionPolicy = ExecutionPolicy.balanced

    /** Max tool-call loop iterations per user turn. */
    var maxToolIterations: Int = 8

    /** If true, boots the server with the valkey-search module so any
     *  ContextStore the agent creates can use `semanticSearch`. Leave
     *  false when you don't need vector retrieval (saves ~1 MB of RAM). */
    var vectorSearch: Boolean = false
}
