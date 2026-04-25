# Dazzle SDK

**An embedded, in-process database for on-device LLM agents.**
Kotlin + Swift, single binary per platform, zero network overhead.

- [Why Dazzle](#why-dazzle) — numbers first
- [Quickstart — Android](#quickstart-android)
- [Quickstart — iOS](#quickstart-ios)
- [LLM adapters](#llm-adapters) — five supported out of the box
- [Context window](#context-window--unbounded-history-smart-retrieval) — what Dazzle promises vs what LLM vendors promise
- [Samples](../../samples/) — three production-shaped chat demos (iOS + Android)
- [API contract](API_CONTRACT.md) — the full cross-platform surface
- [Pinned model catalog](edge_models.json)

---

## Why Dazzle

The one commercial embedded vector DB for mobile —
**SQLiteAI's `sqlite-vector`** — is a SQLite extension retrofitted onto
a general-purpose relational engine that was designed for desktop /
server workloads. Dazzle takes the opposite approach: it's **Valkey 9
compiled for mobile from day one**, with four local patches that kill
every remote-client assumption inside the process (`@static` module
loader, no-listener bypass, bio hooks, per-thread TLS). The read path
has its own snapshot cache that bypasses RESP entirely — the SDK
speaks to storage in typed calls, not serialised bytes.

That shows up in the benchmarks the way you'd expect. **The comparison
that matters** is against the commercial embedded vector database —
**SQLiteAI's `sqlite-vector` extension** (shipped as `vector.xcframework`
on iOS, `libvector.so` on Android, accelerated with their proprietary
`vector_quantize_scan`). That's the only on-device competitor with a
real engineering budget behind it.

### Headline — dim=384 × N=10 000 (BGE-base / E5 / ada-002 scale)

**Android — moto g35 5G (Snapdragon 695)**

| Backend | Retrieval P50 | Recall@10 | Ingest (ms) |
|---|---:|---:|---:|
| **dazzle‑sq8** (int8 + NEON SDOT, ef=10) | **179 µs** | 0.985 | 2 976 |
| dazzle‑sq8 + fp32 rerank (ef=10) | 300 µs | **0.998** | 3 026 |
| dazzle‑vector (HNSW fp32, ef=10) | 275 µs | 0.993 | 10 430 |
| dazzle‑f16 (ef=10) | 274 µs | 0.995 | 6 161 |
| **sqlite‑vector‑ai** (SQLiteAI commercial, quantize_scan) | 1 604 µs | 0.993 | **385** |

- **9× faster retrieval** at matching recall (0.985 vs 0.993).
- **5.3× faster AND higher recall** with sq8+rerank (0.998 vs 0.993).
- sqlite‑vector‑ai wins ingest (385 ms vs Dazzle's 3 s) — honest loss
  for workloads that rebuild the full index from scratch each run.

### Hardcore — dim=1024 × N=10 000 (OpenAI `text-embedding-3-large`, ada-002)

| Backend | Retrieval P50 | Recall@10 | Ingest (ms) |
|---|---:|---:|---:|
| **dazzle‑sq8** (ef=10) | **298 µs** | 0.977 | 8 065 |
| dazzle‑sq8 + fp32 rerank (ef=10) | 452 µs | 0.986 | 7 459 |
| dazzle‑f16 (ef=10) | 596 µs | 0.985 | 14 929 |
| **sqlite‑vector‑ai** | 3 850 µs | 0.990 | **873** |

- **12.9× faster retrieval** — the gap *widens* at higher dim because
  NEON SDOT scales linearly with dim while sqlite-vector-ai's per-row
  overhead stays roughly constant.

### iPhone 12 Pro (A14 Bionic) — dim=384 × N=10 000

| Backend | Retrieval P50 | Recall@10 | Ingest (ms) |
|---|---:|---:|---:|
| **dazzle‑sq8** (int8 + NEON SDOT, ef=10) | **38 µs** | 0.776 | 1 720 |
| dazzle‑sq8 + fp32 rerank (ef=200) | 322 µs | **0.997** | 1 757 |
| dazzle‑vector (HNSW fp32, ef=10) | 103 µs | 0.829 | 4 511 |
| dazzle‑f16 (ef=10) | 102 µs | 0.857 | 4 411 |
| ~~sqlite‑vector‑ai~~ | — | — | — |

> **Why `sqlite-vector-ai` has no iOS row**: Apple's system `libsqlite3`
> deprecated process-global auto extensions in iOS 12 and never shipped
> `sqlite3_load_extension`, so SQLiteAI's extension binary has no
> supported way to attach to an iOS SQLite connection. Dazzle is the
> only engine that actually runs the full vector path on iPhone.

Full benchmark tables (11 Android backends, 9 iOS backends, ablation
factorial 2³, hardcore vector sweep at dim 384/768/1024) are
released alongside the paper.

### Where the speed comes from — briefly

- **No TCP.** Default `tcpEnabled = false`. Every primitive goes
  through a JNI pipe + a `CLIENT_ID_CACHED_RESPONSE` fake client
  inside Valkey. Zero syscalls beyond memory.
- **No RESP on the read path.** A snapshot cache (`dazzle_snapshot_*`)
  holds the most recent hash / set / sorted‑set / string value as
  native C arrays. `HashKey.getAllDirect()`, `SetKey.membersDirect()`,
  `SortedSetKey.rangeByScoreDirect()`, `StringKey.getDirect()` skip
  both the server‑side RESP encode and the client‑side Resp parser.
- **SIMD everywhere.** hnswlib compiled with
  `-march=armv8.2-a+fp16+dotprod`; `simsimd_cos_i8_neon` for SQ8,
  `simsimd_dot_f16_neon` for F16.
- **Single static binary.** `libdazzle.so` (Android) and
  `Dazzle.xcframework` (iOS) embed Valkey 9 + hnswlib + simsimd + the
  vector‑search module + TFI — one `System.loadLibrary` / one
  `import DazzleC` gets you everything.

---

## Quickstart — Android

```kotlin
// 1. Add to app/build.gradle.kts
dependencies {
    implementation("dev.dazzle:dazzle-sdk:1.0.0-beta.4")
}

// 2. Boot + use
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.DazzleConfig

DazzleServer.start(context, DazzleConfig())   // in‑process, no TCP

val dazzle = DazzleServer.client()
val memory = dazzle.hash("agent:chat:turn_1")
memory.set("role", "user")
memory.set("text", "What's the weather in Lima?")

// Fast-path read (snapshot typed, ~14 µs)
val turn = memory.getAllDirect()
```

Full end‑to‑end chat agent:

```kotlin
import dev.dazzle.sdk.edge.DazzleEdge
import dev.dazzle.sdk.edge.LlamaCppClient
import java.io.File

val llm = LlamaCppClient(
    modelFile = File(context.filesDir, "qwen2.5-1.5b.Q4_K_M.gguf")
)
val agent = DazzleEdge.chatAgent(context, llm = llm)
agent.send("Explain quantisation in one sentence.")
```

---

## Quickstart — iOS

```swift
// 1. Add to Package.swift
.package(url: "https://github.com/IvanAliaga/dazzle.git", branch: "main")

// 2. Target dependency
.product(name: "Dazzle", package: "dazzle"),

// 3. Boot + use
import Dazzle

let server = DazzleServer.shared
_ = try server.start(config: DazzleConfig())

let client = server.client()
let memory = client.hash("agent:chat:turn_1")
try memory.set("role", value: "user")
try memory.set("text", value: "What's the weather in Lima?")

let turn = try memory.getAllDirect()   // fast path
```

Full end‑to‑end chat agent:

```swift
import Dazzle

let modelURL = Bundle.main.url(
    forResource: "qwen2.5-1.5b.Q4_K_M",
    withExtension: "gguf"
)!
let llm = try await LlamaCppClient(modelURL: modelURL)
let agent = try DazzleEdge.chatAgent(llm: llm)
agent.send("Explain quantisation in one sentence.")
```

---

## LLM adapters

Dazzle is **runtime‑agnostic**. Five first‑party adapters ship; add your
own by implementing the three‑method `LLMClient` protocol.

| Adapter | Runs on | Covers | Bundled |
|---|---|---|---|
| `LlamaCppClient` | Android + iOS | Any GGUF model (Llama 3, Gemma, Qwen, Phi, DeepSeek, Mistral) | ✅ llama.cpp embedded in the binary |
| `LiteRtLmClient` | Android + iOS | Google's `.litertlm` format (Gemma 4 E2B, Llama 3.2 3B, Qwen 2.5 1.5B) | ✅ opt‑in module |
| `FoundationModelsClient` | iOS 26+ / macOS 26+ | Apple Intelligence 3 B on‑device | — system framework |
| `OpenAICompatibleClient` | Android + iOS | OpenAI / HuggingFace Inference / Ollama / vLLM / Groq / Together / any proxy | — HTTPS only, no native deps |
| `AnthropicClient` | Android + iOS | Anthropic `/v1/messages` API (Claude Haiku / Sonnet / Opus) — distinct shape from OpenAI (system top-level, tool-use as content blocks, `content_block_*` SSE events) auto-translated by the SDK | — HTTPS only, no native deps |

Swap adapters by changing one line; every one emits the same
`Delta.text` / `Delta.toolCallStart` / `Delta.toolCallArgs` shape so
the `ChatAgent` / `Tool` loop is unchanged.

Example — use OpenAI‑compatible instead of llama.cpp:

```kotlin
val llm = OpenAICompatibleClient(
    baseURL = "https://router.huggingface.co/v1",
    model   = "meta-llama/Llama-3.3-70B-Instruct",
    apiKey  = BuildConfig.HF_TOKEN,
)
val agent = DazzleEdge.chatAgent(context, llm = llm)
```

Example — Anthropic Messages API (Claude):

```kotlin
val llm = AnthropicClient(
    model     = "claude-haiku-4-5-20251001",
    apiKey    = System.getProperty("dazzle.anthropic_key", ""),
    maxTokens = 1024,
)
val agent = DazzleEdge.chatAgent(context, llm = llm)
```

Verified end-to-end against `api.anthropic.com` on all four
stacks (RN Android / iOS native / Flutter Android / Flutter iOS
sim) — see [`samples/PROVIDERS.md`](../../samples/PROVIDERS.md)
for the live verification matrix.

---

## Context window — unbounded history, smart retrieval

Big‑tech LLM vendors advertise **1 M‑token context windows** (Gemini
1.5 Pro) or **200 k** (Claude 3.5 Sonnet). That number is a property of
the **model runtime**, not the database. What Dazzle *does* own:

1. **Persistent history** — `ContextStore<ChatTurn>` can hold millions
   of turns on device at ~30 µs per read (iPhone 12 Pro).
2. **Which subset enters the next prompt** — a `ContextWindow` policy
   picks `lastN`, `all`, or **`vectorRecall`** (semantic retrieval of
   the most relevant past turns, plus a fixed recency slice).
3. **Compaction** — `CompactionPolicy.rollingSummary` LLM‑summarises
   old turns so the same logical history fits into a smaller prompt.

The usable context window depends on which runtime you plug in and,
for on‑device adapters, on device RAM (the KV cache scales with
`n_ctx × n_layers × 2 × sizeof(fp16)`):

| Adapter | Native max | Realistic on‑device | Recommended `ContextWindow` |
|---|---:|---:|---|
| `LlamaCppClient` (Qwen 2.5 1.5B Q4) | 32 768 | 2 048–8 192 (iPhone 12 Pro: 8 k OK / moto g35: 2–4 k) | `.vectorRecall(keepRecent:10, k:5)` |
| `LlamaCppClient` (Llama 3.2 3B Q4) | 131 072 | 4 096–16 384 | `.vectorRecall` + `.rollingSummary` |
| `LiteRtLmClient` (Gemma 4 E2B) | 8 192 | 8 192 (native) | `.lastN(40)` or `.vectorRecall` |
| `FoundationModelsClient` (iOS 26+) | ~4 096 | 4 096 | `.vectorRecall` + `.rollingSummary` (must) |
| `OpenAICompatibleClient` (GPT‑4o‑mini) | 128 000 | 128 000 | `.vectorRecall` still wins on token cost |
| `OpenAICompatibleClient` (Gemini 1.5 Pro via HF Router) | 1 000 000+ | 1 000 000 | `.all` works, `.vectorRecall` cheaper |

> **Why a 4 k window with `.vectorRecall` often beats a 1 M window with
> `.all`** — retrieval returns the N *most relevant* turns; the model
> sees concentrated signal. A 1 M prompt dilutes relevance across
> orders of magnitude more tokens and, in most benchmarks, degrades
> answer quality (the "lost‑in‑the‑middle" effect).

Set the policy in a single line when you build the agent:

```swift
let agent = server.client().chatAgent(threadId: "user-42", llm: llm) {
    $0.contextWindow = .vectorRecall(
        keepRecent: 10,
        k: 5,
        store: embeddingStore,
        embedder: mySmallEmbedder
    )
    $0.compaction = .rollingSummary(
        everyNTurns: 20,
        keepRecent: 10,
        summarizer: { oldTurns in
            try await llm.complete(messages: [
                Message(role: .user,
                        content: "Summarise these turns in 2 lines:\n\(oldTurns.map(\.text).joined(separator: \"\\n\"))")
            ]).text
        }
    )
}
```

---

## What's next

- [Samples](../../samples/) — three ready-to-run chat apps (iOS + Android)
  demonstrating the three retrieval patterns (`chat-memory`,
  `chat-iot`, `chat-kb`) with all four LLM adapters swappable via a
  single file.
- [CHANGELOG](../../CHANGELOG.md) — latest tag is `1.0.0-beta.4`
  (5th LLM adapter — `AnthropicClient` — across all four stacks,
  three EventChannel bridge fixes applied preventively to every
  Flutter bridge, RN wrapper deduplication via shared
  `_nativeLLMStream` helper, live verification 4/4 against
  `api.anthropic.com`).
- [Roadmap](../ROADMAP.md) — what's landing next (Layer 4 multi‑agent
  `Channel<T>`, SHA‑256 manifest pinning, Dokka / DocC polish).
- [API contract](API_CONTRACT.md) — the canonical surface both
  platforms implement, feature by feature.
