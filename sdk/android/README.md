# dazzle-sdk (Android)

Native Kotlin SDK for [Dazzle](https://github.com/IvanAliaga/dazzle-sdk) —
the embedded, in-process database for on-device LLM agents.

Latest: **v1.0.0-beta.5** — see
[../../CHANGELOG.md](../../CHANGELOG.md).

## Install

### Maven Central

```kotlin
// build.gradle.kts (app)
dependencies {
    implementation("com.ivanaliaga:dazzle-sdk:1.0.0-beta.5")
    // Only if you use the bundled LiteRT-LM adapter:
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")
}
```

### Local Maven repo (SDK contributors)

```bash
# From the repo root — for working from the source tree
samples/_scripts/link_flutter.sh android   # publishes com.ivanaliaga:dazzle-sdk:* into sdk/android/build/maven-repo/
```

Then in your app's `build.gradle.kts`:

```kotlin
repositories {
    maven { url = uri("$rootDir/path/to/sdk/android/build/maven-repo") }
}
dependencies {
    implementation("com.ivanaliaga:dazzle-sdk:1.0.0-beta.5")
    // Only if you use the bundled LiteRT-LM adapter:
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")
}
```

### Composite build (SDK development)

```kotlin
// settings.gradle.kts
includeBuild("../path/to/sdk/android")

// build.gradle.kts
dependencies {
    implementation("com.ivanaliaga:dazzle-sdk")
}
```

## Minimum target

| Setting              | Value     |
|----------------------|-----------|
| `minSdk`             | 26        |
| `compileSdk`         | 35        |
| `ndk { abiFilters }` | `arm64-v8a` (only ABI shipped today) |
| Kotlin               | 2.2.x     |

## Hello world

```kotlin
import android.content.Context
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.edge.DazzleEdge
import dev.dazzle.sdk.edge.LlamaCppClient
import java.io.File

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // Boot the in-process Valkey server. <100 ms on Moto G35 5G.
        DazzleServer.start(this, DazzleConfig())
    }
}

suspend fun reply(ctx: Context, prompt: String): String {
    val gguf = File(ctx.filesDir, "qwen2.5-1.5b-instruct-q4_k_m.gguf")
    val llm = LlamaCppClient(modelFile = gguf)

    val agent = DazzleEdge.chatAgent(ctx, llm = llm, threadId = "session:42") {
        systemPrompt = "You are a helpful on-device AI assistant."
    }
    agent.send(prompt)
    return agent.messages.value.last().text
}
```

## LLM adapters

Five adapters ship — pick the one your model needs, every one emits
the same `Delta` shape so the surrounding `ChatAgent` / `Tool` loop
is identical.

| Adapter                  | Class                                                | Use when                                                            |
|--------------------------|------------------------------------------------------|---------------------------------------------------------------------|
| `LlamaCppClient`         | `dev.dazzle.sdk.edge.LlamaCppClient`                 | Any GGUF model on-device (Llama, Gemma, Qwen, Phi, Mistral, …)      |
| `LiteRtLmClient`         | `dev.dazzle.sdk.edge.LiteRtLmClient`                 | Google's `.litertlm` format (Gemma 4 E2B, Llama 3.2 3B, …)          |
| `OpenAICompatibleClient` | `dev.dazzle.sdk.edge.OpenAICompatibleClient`         | OpenAI / HF Router / Ollama / vLLM / Groq / Together / any proxy    |
| `AnthropicClient`        | `dev.dazzle.sdk.edge.AnthropicClient`                | Anthropic `/v1/messages` (Claude Haiku / Sonnet / Opus)             |

(`FoundationModelsClient` is iOS-only; on Android you'd ship the LiteRT
or GGUF runtime instead.)

`OpenAICompatibleClient` and `AnthropicClient` use only the JDK
(`HttpURLConnection` + `org.json`) — no extra HTTP library
dependency.

## Documentation

- Quickstart + benchmarks: [`docs/sdk/README.md`](../../docs/sdk/README.md)
- API contract (cross-platform surface): [`docs/sdk/API_CONTRACT.md`](../../docs/sdk/API_CONTRACT.md)
- Architecture (transport, snapshot cache, worker pool): [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md)
- LLM provider matrix + live verification: [`samples/PROVIDERS.md`](../../samples/PROVIDERS.md)
- Roadmap: [`docs/ROADMAP.md`](../../docs/ROADMAP.md)

## Samples

Three production-shaped demos live under
[`samples/`](../../samples/):

- [`samples/chat-memory`](../../samples/chat-memory) — pure conversational history
- [`samples/chat-iot`](../../samples/chat-iot) — tool-calling + SortedSet retrieval
- [`samples/chat-kb`](../../samples/chat-kb) — vector search (HNSW_SQ8) RAG

Each has a headless `SAMPLE_TEST=1` mode that drives the full
ChatAgent + tool loop, writes a JSON report, and exits — see
`samples/_scripts/test_android.sh`.

## License

Apache 2.0 — see [LICENSE](../../LICENSE). Valkey portions remain
under BSD-3-Clause; see [ATTRIBUTION.md](../../ATTRIBUTION.md).
