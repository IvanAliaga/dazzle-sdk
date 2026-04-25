# Dazzle (iOS / Swift)

Native Swift SDK for [Dazzle](https://github.com/IvanAliaga/dazzle) —
the embedded, in-process database for on-device LLM agents.

Latest: **v1.0.0-beta.4** — see
[../../CHANGELOG.md](../../CHANGELOG.md).

## Install

The SDK ships as **`Dazzle.xcframework`**, produced by
`sdk/ios/build.sh` (one-time, ~3 min). Two opt-in products:

- **`Dazzle`** — primitives + `ContextStore` + `ChatAgent` + the
  `DazzleEdge` factory, plus `LlamaCppClient`, `OpenAICompatibleClient`,
  `AnthropicClient`, and `FoundationModelsClient` (gated behind
  iOS 26 availability checks). No extra binary cost.
- **`DazzleLiteRTLM`** — opt-in product that pulls
  [`LiteRTLM-Swift`](https://github.com/mylovelycodes/LiteRTLM-Swift)
  (~80 MB `CLiteRTLM.xcframework`). Only consumers that actually
  instantiate `LiteRtLmClient` pay this cost.

### SwiftPM (recommended)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/IvanAliaga/dazzle.git",
             .exact("1.0.0-beta.4")),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Dazzle", package: "dazzle"),
        // .product(name: "DazzleLiteRTLM", package: "dazzle"), // optional
    ]),
]
```

### Xcode project (xcodegen)

```yaml
# project.yml
packages:
  Dazzle:
    url: https://github.com/IvanAliaga/dazzle.git
    exactVersion: 1.0.0-beta.4
targets:
  MyApp:
    dependencies:
      - package: Dazzle
        product: Dazzle
```

### Local source dependency (for SDK development)

```yaml
# project.yml of the sample
sources:
  - path: ../../../sdk/ios/Sources
  - path: ../../../sdk/ios/cshim
  # plus the xcframework binary target
```

The three iOS samples under `samples/chat-*` use this layout — see
`samples/chat-memory/ios/project.yml` for a complete example.

## Minimum target

| Setting              | Value     |
|----------------------|-----------|
| Deployment target    | iOS 17.0  |
| Architectures        | `arm64` device + `arm64` simulator (Apple Silicon Macs) |
| Swift                | 5.9       |
| Xcode                | 15.0+     |

`x86_64` simulator slices are not shipped (Apple Silicon Macs only).

## Hello world

```swift
import Dazzle

@main
struct MyApp: App {
    init() {
        // In-process Valkey server. <100 ms on iPhone 12 Pro.
        try? DazzleServer.shared.start(config: DazzleConfig())
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

func reply(prompt: String) async throws -> String {
    let modelURL = Bundle.main.url(
        forResource: "qwen2.5-1.5b-instruct-q4_k_m",
        withExtension: "gguf")!
    let llm = try await LlamaCppClient(modelURL: modelURL)

    let agent = try DazzleEdge.chatAgent(llm: llm, threadId: "session:42")
    agent.send(prompt)
    // SwiftUI: bind `agent.messages` / `agent.streaming` / `agent.status`.
    while await agent.status.value != .idle { try await Task.sleep(for: .milliseconds(50)) }
    return await agent.messages.value.last?.text ?? ""
}
```

## LLM adapters

Five adapters ship — every one emits the same `Delta` shape so the
surrounding `ChatAgent` / `Tool` loop is identical when you swap them.

| Adapter                  | Class                                       | Use when                                                                          |
|--------------------------|---------------------------------------------|-----------------------------------------------------------------------------------|
| `LlamaCppClient`         | `Dazzle.LlamaCppClient`                     | Any GGUF model on-device (Llama, Gemma, Qwen, Phi, Mistral, …)                    |
| `LiteRtLmClient`         | `DazzleLiteRTLM.LiteRtLmClient`             | Google's `.litertlm` format (we ship the iOS port — nobody else has LiteRT-LM iOS) |
| `FoundationModelsClient` | `Dazzle.FoundationModelsClient`             | Apple Intelligence on iOS 26+ / macOS 26+ — gate with `FoundationModelsClient.isAvailable` |
| `OpenAICompatibleClient` | `Dazzle.OpenAICompatibleClient`             | OpenAI / HF Router / Ollama / vLLM / Groq / Together / any proxy                  |
| `AnthropicClient`        | `Dazzle.AnthropicClient`                    | Anthropic `/v1/messages` (Claude Haiku / Sonnet / Opus)                           |

`OpenAICompatibleClient` and `AnthropicClient` use only `URLSession`
+ `JSONSerialization` — no extra HTTP library dependency.

## Documentation

- Quickstart + benchmarks: [`docs/sdk/README.md`](../../docs/sdk/README.md)
- API contract (cross-platform surface): [`docs/sdk/API_CONTRACT.md`](../../docs/sdk/API_CONTRACT.md)
- Architecture (transport, snapshot cache, worker pool): [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md)
- LLM provider matrix + live verification: [`samples/PROVIDERS.md`](../../samples/PROVIDERS.md)
- Roadmap: [`docs/ROADMAP.md`](../../docs/ROADMAP.md)

## Samples

Three production-shaped demos live under
[`samples/`](../../samples/):

- [`samples/chat-memory`](../../samples/chat-memory) — pure
  conversational history
- [`samples/chat-iot`](../../samples/chat-iot) — tool-calling +
  SortedSet retrieval
- [`samples/chat-kb`](../../samples/chat-kb) — vector search
  (HNSW_SQ8) RAG

Each has a headless `SAMPLE_TEST=1` mode that drives the full
ChatAgent + tool loop, writes a JSON report, and exits — see
`samples/_scripts/test_ios.sh`.

## Building the xcframework from source

```bash
# From the repo root, one-time (3-5 min)
bash sdk/ios/build.sh
```

This fetches Valkey, applies the patches under `versions/`, builds
each architecture slice, and packages everything as
`sdk/ios/Dazzle.xcframework`. The xcframework includes
`libvalkey-server.a` and a `module.modulemap` that exposes the
`DazzleC` C-shim module to Swift.

## License

Apache 2.0 — see [LICENSE](../../LICENSE). Valkey portions remain
under BSD-3-Clause; see [ATTRIBUTION.md](../../ATTRIBUTION.md).
