# DazzleEdge — the Layer 3 bundle (design spec)

Status: **draft, not yet implemented**. This document locks the shape of
the Layer 3 `DazzleEdge` bundle so the Layer 2 primitives it builds on
don't drift as we add use-case kits.

## Why this exists

Layer 2 (`ContextStore<T>`, `Tool<Args, Ret>`, `LLMClient`, `Agent`,
`ExecutionPolicy`, …) gives **advanced developers** all the knobs they
need to assemble an on-device agent from first principles. It does not
make 80 % of developers productive in 10 lines.

DazzleEdge is the **one-liner on-ramp** — a pre-wired bundle of:

- A default `LLMClient` backed by a known local inference runtime
  (LiteRT-LM on both platforms, Foundation Models on iOS 18+ when
  available).
- Sensible `DazzleConfig` tuned for the current device class.
- A default `ContextStore<ChatTurn>` as chat memory with threadId
  resumption.
- A default `CompactionPolicy` and `ContextWindow` that won't crash the
  LLM on long sessions.
- Automatic tool-call plumbing (the Layer 2 `Agent` already handles
  this — DazzleEdge just registers the bundle's default tools).
- **Model download** with progress callbacks for known models; BYOM
  escape hatch for custom weights.

Advanced developers bypass DazzleEdge and use Layer 2 directly. Both
paths must remain first-class.

## Public API shape

### Android (Kotlin)

```kotlin
object DazzleEdge {

    /**
     * Known models with pinned URL + sha256. Lazy-downloaded to the
     * app's cache directory on first use; cached across launches.
     */
    sealed class Model {
        data object Gemma3nE2B : Model()       // 2.4 GB, chat + tools
        data object Llama32_3B : Model()       // 1.5 GB, slim
        data object Qwen25_1B5B : Model()      // 0.9 GB, smallest

        /** Bring your own — dev provides the file + backend. */
        data class Custom(val file: File, val backend: Backend) : Model()

        enum class Backend { LiteRTLM, LlamaCpp }
    }

    /**
     * One-liner chat agent. Boots Dazzle + loads the model + wires
     * memory/compaction/context-window to sensible defaults.
     */
    suspend fun chatAgent(
        context: Context,
        threadId: String = "default",
        build: ChatAgentBuilder.() -> Unit = {},
    ): Agent

    /** Same as `chatAgent` but wires a RAG knowledge store. */
    suspend fun ragAgent(
        context: Context,
        threadId: String = "default",
        knowledgeStore: ContextStore<*>,
        build: ChatAgentBuilder.() -> Unit = {},
    ): Agent

    /** Release the shared server + shared LLM. Call on app exit. */
    fun shutdown()
}

class ChatAgentBuilder {
    var model: Model = Model.Gemma3nE2B
    var systemPrompt: String = "You are a helpful edge assistant."
    val tools: MutableList<Tool<*, *>> = mutableListOf()
    var contextWindow: ContextWindow = ContextWindow.LastN(20)
    var compaction: CompactionPolicy = CompactionPolicy.RollingSummary(
        everyNTurns = 50, keepRecent = 20,
        summarizer = defaultLlmSummarizer  // wired by the bundle
    )
    var execution: ExecutionPolicy = ExecutionPolicy.balanced

    /** Progress callback for model download. Fires once per ~1% change. */
    fun onModelDownload(fn: (bytesLoaded: Long, bytesTotal: Long) -> Unit)
}
```

### iOS (Swift)

Same shape, Swift idioms:

```swift
public enum DazzleEdge {
    public enum Model {
        case gemma3nE2B
        case llama32_3B
        case qwen25_1B5B
        case custom(url: URL, backend: Backend)
        public enum Backend { case liteRTLM, llamaCpp, foundationModels }
    }

    /// One-liner chat agent.
    public static func chatAgent(
        threadId: String = "default",
        configure: (ChatAgentBundle) -> Void = { _ in }
    ) async throws -> ChatAgentImpl

    public static func ragAgent(
        threadId: String = "default",
        knowledgeStore: any ContextStoreBox,
        configure: (ChatAgentBundle) -> Void = { _ in }
    ) async throws -> ChatAgentImpl

    public static func shutdown()
}

public final class ChatAgentBundle {
    public var model: DazzleEdge.Model = .gemma3nE2B
    public var systemPrompt: String = "You are a helpful edge assistant."
    public var tools: [any ErasedTool] = []
    public var contextWindow: ContextWindow = .lastN(20)
    public var compaction: CompactionPolicy = .rollingSummary(
        everyNTurns: 50, keepRecent: 20,
        summarizer: defaultLlmSummarizer
    )
    public var execution: ExecutionPolicy = .balanced

    public func onModelDownload(_ fn: @Sendable (Int64, Int64) -> Void)
}
```

## Implementation notes (for when this ships)

### Model download

- Known models ship with a manifest at `docs/edge_models.json`
  (URL + sha256 + size). The SDK pins the exact versions.
- Download target: `<cacheDir>/dazzle-edge/<model-id>/<version>.litertlm`.
- Parallel-chunked GET with resume on failure (`Range:` header).
- SHA-256 verification after download — refuse to use a mismatching
  file and surface `ModelLoadFailed`.
- When a `Model.Custom(file: ...)` is passed, no download or hashing
  happens — the dev takes responsibility for the artifact.

### LiteRT-LM adapter

Ships as an internal class `LiteRTLMClient: LLMClient` that wraps the
upstream Swift / Kotlin bindings. It:

- Translates `[Message]` → LiteRT-LM's prompt format (ChatML / Gemma
  template, selected per `Model`).
- Parses tool_calls back out of the model's text via the function-
  calling syntax each model was fine-tuned on (`<tool_call>{...}`
  for Gemma; JSON blob with `functions` key for Llama 3.2).
- Emits `Delta.text` / `Delta.toolCallStart` / `Delta.toolCallArgs`
  events as LiteRT-LM yields tokens.

### Shared server

`DazzleEdge` owns a single `DazzleServer` per process. All agents
created through it share that server + share `execution: .balanced`
unless overridden. `DazzleEdge.shutdown()` is the only way the server
is stopped from the Edge bundle.

### Foundation Models (iOS 18+ only)

Detect at runtime; when available, `Model.custom(backend:
.foundationModels)` skips the download entirely and uses the on-device
Apple Intelligence model. Stays behind a compile-time
`#if canImport(FoundationModels)` guard so the SDK still compiles on
iOS 17.

## Out of scope for Layer 3

These are explicitly **not** part of the DazzleEdge bundle:

- Streaming image / audio inputs (Layer 4+).
- Multi-agent pub/sub (already tracked, Layer 4+).
- Model quantization / conversion pipelines — we consume pre-quantized
  artifacts that shippers produce upstream.
- Cloud-fallback orchestration (if the local model fails, fall back to
  a hosted API). Dev wires this themselves via a wrapping `LLMClient`.

## Migration path for existing Layer 2 users

Every Layer 2 concept is reachable from a DazzleEdge agent:

```kotlin
val agent = DazzleEdge.chatAgent(context) { ... }

// "I want to swap the memory store for my own" — reach into the agent
val mem = agent.memory   // exposed on Agent interface

// "I want to add a tool after boot" — tools is MutableList on the interface
agent.tools += mySensorTool

// "I want to use a different LLM client per environment" — build Layer 2 directly
val advanced = dazzle.chatAgent(threadId = "x", llm = myCustomLlm) { ... }
```

No feature is locked behind the bundle — the bundle is strictly a
convenience layer.
