# Dazzle

**An optimized edge database for mobile AI inference.**
**Una base de datos edge optimizada para inferencia de IA en el móvil.**

Built on [Valkey](https://valkey.io/) (Linux Foundation, BSD-3-Clause).
Licensed under Apache 2.0 — see [LICENSE](LICENSE).
Upstream attribution — ver [ATTRIBUTION.md](ATTRIBUTION.md).

**Paper:** *Dazzle: Una Base de Datos Embebida para Agentes LLM en
Dispositivos Móviles.* (under preparation — the paper and full
benchmark data will be released alongside the paper publication).

---

## What's Dazzle? / ¿Qué es Dazzle?

**EN.** Dazzle is a mobile-first fork of Valkey. The server runs
in-process inside the app — no TCP loopback, no background daemon. The
I/O path is a pipe → SPSC ring buffer → `io_uring` batch pipeline; the
read path bypasses the event loop entirely via a snapshot cache.
Everything is wired so an on-device LLM can build its prompt context
from hundreds of keys in a single in-process round-trip.

- In-process Valkey derivative optimised for mobile
- Eliminates TCP overhead (pipe-based I/O)
- Supports edge LLM inference with context injection
- Android + iOS support

**ES.** Dazzle es un fork de Valkey pensado para móvil. El servidor
corre dentro del proceso de la app — sin loopback TCP, sin daemon en
segundo plano. La ruta de escritura es pipe → ring buffer SPSC → batch
`io_uring`; la de lectura esquiva el event loop mediante un snapshot
cache. Todo está cableado para que un LLM on-device pueda armar su
contexto a partir de cientos de keys en un solo ida y vuelta
in-process.

- Derivado in-process de Valkey, optimizado para móvil
- Sin overhead de TCP (I/O por pipe)
- Inferencia LLM en el edge con inyección de contexto
- Soporte Android + iOS

---

## Relationship to Valkey / Relación con Valkey

**EN.** Dazzle is a fork of Valkey optimised for mobile edge computing.
Valkey itself is not vendored in this repository — its source is fetched
at build time (`FetchContent` on Android, `git clone` on iOS) and patched
with the diffs under [`versions/`](versions/). See
[ATTRIBUTION.md](ATTRIBUTION.md) for the Valkey copyright notice.

**ES.** Dazzle es un fork de Valkey optimizado para edge computing en
móvil. Valkey no vive en este repo — se descarga en build time
(`FetchContent` en Android, `git clone` en iOS) y se parchea con los
diffs en [`versions/`](versions/). El aviso de copyright de Valkey
está en [ATTRIBUTION.md](ATTRIBUTION.md).

---

## Repository layout / Estructura del repo

```
dazzle/
├── core/                     # Dazzle IP — new I/O model
│   ├── transport/            #   pipe → SPSC ring → io_uring
│   ├── cache/                #   snapshot cache (lock-free reads)
│   ├── platform/             #   iOS C bridge
│   └── compat/               #   v8/v9/v10+ API shims
├── versions/                 # Build-time patches over upstream Valkey
│   ├── v8/patches/
│   └── v9/patches/
├── sdk/
│   ├── android/              # AAR library + demo app (Kotlin)
│   ├── ios/                  # XCFramework + demo app (Swift / SwiftPM)
│   ├── flutter/              # dazzle_flutter plugin (Dart + dart:ffi)
│   └── react-native/         # dazzle-react-native package (TS + sync bridge)
├── samples/                  # 12 production-shaped demos (4 stacks × 3 patterns)
├── docs/                     # Architecture + per-platform guides
├── tests/                    # C-core unit tests (transport, snapshot)
├── README.md
├── CHANGELOG.md
├── ATTRIBUTION.md
└── LICENSE                   # Apache 2.0
```

---

## Transport phases / Fases del transporte

| Phase / Fase | What it does / Qué hace | Status / Estado |
|---|---|---|
| 0 | In-process pipe — eliminates TCP / elimina TCP | ✅ |
| 1 | Snapshot cache `directRead` — reads skip the event loop / lecturas sin event loop | ✅ 240 µs on Moto G35 |
| 2 | SPSC ring buffer + `eventfd` — lock-free writes / escrituras lock-free | ✅ |
| 3 | `io_uring` batch — 1 syscall per N commands / 1 syscall cada N comandos | ✅ |
| 4 | Worker pool direct app→Dict — parallel reads / lecturas en paralelo | ✅ SoC-aware (2–4 workers), 23 375 retrievals/s @ p99 <1 ms |
| 5 | Typed JNI — `String[]` without RESP / sin RESP | 🔨 partial / parcial |
| 6 | `suspend fun` SDK — coroutine-native / SDK basado en corutinas | ✅ Android + iOS paridad |

Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Headline benchmarks — Dazzle vs `sqlite-vector-ai` (SQLiteAI commercial)

The comparison that matters: the commercial embedded vector extension
from SQLiteAI (`vector.xcframework` / `libvector.so`), accelerated via
their proprietary `vector_quantize_scan`. Apples-to-apples on the same
phone, same corpus, same ef.

**Moto g35 5G (Snapdragon 695)** — dim=384, N=10 000, ef=10:

| Backend | Retrieval P50 | Recall@10 |
|---|---:|---:|
| **dazzle-sq8** (int8 + NEON SDOT) | **179 µs** | 0.985 |
| dazzle-sq8 + fp32 rerank | 300 µs | **0.998** |
| `sqlite-vector-ai` | 1 604 µs | 0.993 |

→ **9× faster at matching recall**; **5.3× faster AND higher recall**
with sq8+rerank.

**Moto g35 5G — hardcore dim=1024** (OpenAI `text-embedding-3-large`):

| Backend | Retrieval P50 | Recall@10 |
|---|---:|---:|
| **dazzle-sq8** | **298 µs** | 0.977 |
| `sqlite-vector-ai` | 3 850 µs | 0.990 |

→ **12.9× faster** — the gap widens at higher dim (NEON SDOT scales
linearly while sqlite-vector-ai's per-row overhead stays constant).

**iPhone 12 Pro (A14 Bionic)** — dim=384, N=10 000, ef=10:

| Backend | Retrieval P50 | Recall@10 |
|---|---:|---:|
| **dazzle-sq8** | **38 µs** | 0.776 |
| dazzle-sq8 + fp32 rerank (ef=200) | 322 µs | **0.997** |

> `sqlite-vector-ai` has no iOS row: Apple's system `libsqlite3`
> deprecated process-global auto extensions in iOS 12 and never shipped
> `sqlite3_load_extension`, so SQLiteAI's xcframework has no supported
> way to attach to an iOS SQLite connection. Dazzle is the only engine
> that actually runs the full vector path on iPhone.

Full tables and raw JSONs are released alongside the paper.

---

## Modules / Módulos

### valkey-search (HNSW) + dazzle-vector

**EN.** The [`valkey-search`](https://github.com/valkey-io/valkey-search)
HNSW module is built in-tree and loaded at boot; `dazzle-vector` uses it
for semantic memory over sensor windows. The experiment dataset ships
NAMUR NE43 status codes (`OK / NO_DATA / OUT_OF_RANGE / FAULT /
CALIB_ERROR`) so a retrieval can surface prior windows with the same
fault signature.

**ES.** El módulo HNSW [`valkey-search`](https://github.com/valkey-io/valkey-search)
se compila en el árbol y se carga al arranque; `dazzle-vector` lo usa
para memoria semántica sobre ventanas de sensor. El dataset del
experimento incluye códigos NAMUR NE43 (`OK / NO_DATA / OUT_OF_RANGE /
FAULT / CALIB_ERROR`) para que un retrieval pueda traer ventanas
previas con la misma firma de falla.

---

## Quick start — SDK usage / Uso del SDK

**Latest release**: `v1.0.0-beta.4` — see
[CHANGELOG.md](CHANGELOG.md) and the
[API contract](docs/sdk/API_CONTRACT.md).

### LLM adapters / Adaptadores LLM

Dazzle ships **five** `LLMClient` implementations, all swappable
behind the same `ChatAgent` API across the four stacks:

| Adapter                  | What it talks to                                                                  | Networking |
|--------------------------|-----------------------------------------------------------------------------------|---|
| `LlamaCppClient`         | Any GGUF model (Llama, Gemma, Qwen, Phi, Mistral, …). Default Qwen 2.5.           | on-device |
| `LiteRtLmClient`         | Google's `.litertlm` format (Android + our iOS port).                             | on-device |
| `FoundationModelsClient` | Apple Intelligence on iOS 26+ / macOS 26+.                                        | on-device |
| `OpenAICompatibleClient` | OpenAI, Azure OpenAI, HF Router, Ollama, vLLM, Groq, Together, llama-server, …   | cloud     |
| `AnthropicClient`        | Anthropic `/v1/messages` (Claude Haiku / Sonnet / Opus).                          | cloud     |

Live verification matrix against `api.anthropic.com`: 4/4 stacks
PASS — see [`samples/PROVIDERS.md`](samples/PROVIDERS.md).

### Android — one-liner agent / Agente en una línea

```kotlin
// build.gradle.kts (app)
dependencies {
    implementation("com.ivanaliaga:dazzle-sdk:1.0.0-beta.4")
    // Only if you use the bundled LiteRT-LM adapter:
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")
}
```

```kotlin
import dev.dazzle.sdk.edge.DazzleEdge
import dev.dazzle.sdk.edge.LiteRtLmClient

// 1. Fetch / reuse the model
val modelFile = DazzleEdge.ensureModel(context) { loaded, total ->
    updateProgress(loaded, total)
}

// 2. Plug in any LLMClient — Dazzle ships a LiteRT-LM one, or bring your own
val llm = LiteRtLmClient(modelFile = modelFile, context = context)

// 3. Start chatting — the agent owns memory + compaction + tool loop
val agent = DazzleEdge.chatAgent(context, llm = llm, threadId = "session:42") {
    systemPrompt = "You are a helpful on-device assistant."
    tools += sensorRecallTool
}

agent.send("¿qué temperatura hay ahora?")
lifecycleScope.launch {
    agent.messages.collect { turns -> render(turns) }
}
```

### iOS — same shape / mismo shape

```swift
// Package.swift (your app)
.package(url: "https://github.com/IvanAliaga/dazzle.git", .exact("1.0.0-beta.4")),

// Target dependencies
.product(name: "Dazzle", package: "dazzle"),
.product(name: "DazzleLiteRTLM", package: "dazzle"),  // opt-in LLM runtime
```

```swift
import Dazzle
import DazzleLiteRTLM

let modelURL = try await DazzleEdge.ensureModel { loaded, total in
    await MainActor.run { updateProgress(loaded, total) }
}
let llm = try await LiteRtLmClient(modelURL: modelURL)

let agent = try DazzleEdge.chatAgent(llm: llm, threadId: "session:42") { cfg in
    cfg.systemPrompt = "You are a helpful on-device assistant."
    cfg.tools = [sensorRecallTool]
}

agent.send("¿qué temperatura hay ahora?")
// SwiftUI `@Bindable var agent: ChatAgentImpl` reacts to messages/streaming/status
```

### Flutter — same shape / mismo shape

```yaml
# pubspec.yaml
dependencies:
  dazzle_flutter:
    path: ../path/to/sdk/flutter/dazzle_flutter   # dev flow
    # pub.dev version lands after GA
```

```dart
import 'package:dazzle_flutter/dazzle_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DazzleServer.shared.start();

  final llm = await LlamaCppClient.create(modelPath: '/path/to/qwen.gguf');
  final agent = DazzleServer.shared.chatAgent(
    threadId: 'session:42',
    llm: llm,
    systemPrompt: 'You are a helpful on-device assistant.',
    tools: [sensorRecallTool],
  );

  await agent.send('¿qué temperatura hay ahora?');
  // Bind the 3 ValueNotifiers (messages / streaming / status) into your UI.
}
```

### React Native — same shape / mismo shape

```json
// package.json
"dependencies": {
  "dazzle-react-native": "file:../path/to/sdk/react-native/dazzle-react-native"
}
```

```ts
import {
  ChatAgent, DazzleServer, OpenAICompatibleClient,
} from 'dazzle-react-native';

await DazzleServer.shared.start();

const llm = new OpenAICompatibleClient({
  baseURL: 'https://api.openai.com/v1',
  model: 'gpt-4o-mini',
  apiKey: process.env.OPENAI_API_KEY,
});

const agent = new ChatAgent({
  threadId: 'session:42',
  llm,
  systemPrompt: 'You are a helpful on-device assistant.',
  tools: [sensorRecallTool],
});

agent.messages.subscribe((turns) => render(turns));
await agent.send('¿qué temperatura hay ahora?');
```

Full API reference: [docs/sdk/API_CONTRACT.md](docs/sdk/API_CONTRACT.md).
DazzleEdge bundle spec: [docs/architecture/edge_bundle.md](docs/architecture/edge_bundle.md).
Known gaps + roadmap: [docs/ROADMAP.md](docs/ROADMAP.md).
Flutter quickstart: [docs/sdk/flutter-quickstart.md](docs/sdk/flutter-quickstart.md).
React Native quickstart: [docs/sdk/react-native-quickstart.md](docs/sdk/react-native-quickstart.md).

## Quick start — demo apps / Aplicaciones demo

### iOS

```bash
# Build the XCFramework (one-time, ~3 min) / Construir el XCFramework
bash sdk/ios/build.sh

# Open the demo app / Abrir la demo
cd sdk/ios/demo
xcodegen generate
open DazzleDemo.xcodeproj
```

### Android

```bash
cd sdk/android
./gradlew :demo:installDebug   # requires Android SDK / requiere Android SDK
```

---

## Research benchmarks / Benchmarks de investigación

The full multi-backend benchmark suite (11 Android backends, 9 iOS
backends, vector search at dim=384/768/1024, ablation factorial 2³)
is part of the paper preparation and will be released alongside the
paper. The Headline numbers above this section are reproducible
against the same Moto G35 5G + iPhone 12 Pro hardware once the
benchmark scripts are public.

Las cifras headline arriba son reproducibles contra el mismo Moto
G35 5G + iPhone 12 Pro una vez que se liberen los scripts del
benchmark junto con el paper.

---

## About the name / Sobre el nombre

**EN.** Dazzle is named after a beloved Peruvian dog who brought joy
and inspiration. This project carries his spirit of curiosity and
exploration into edge AI.

**ES.** Dazzle lleva el nombre de un perrito peruano muy querido
que trajo alegría e inspiración. Este proyecto carga su espíritu de
curiosidad y exploración hacia la IA on-device.

---

## License / Licencia

Dazzle is released under the Apache License 2.0 — see
[LICENSE](LICENSE). The Valkey portions remain under BSD-3-Clause —
see [ATTRIBUTION.md](ATTRIBUTION.md).

Dazzle se publica bajo Apache 2.0 — ver [LICENSE](LICENSE). Las partes
correspondientes a Valkey siguen bajo BSD-3-Clause — ver
[ATTRIBUTION.md](ATTRIBUTION.md).
