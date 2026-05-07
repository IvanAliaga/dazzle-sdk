# Flutter quickstart

Build a Dazzle-powered Flutter app end-to-end. Same embedded Valkey +
HNSW vector search + ChatAgent runtime the Android / iOS native SDKs
ship — one API, zero behaviour drift.

Latest: **v1.0.0-beta.5**.

## What you get

- `DazzleServer.shared.start()` — embedded Valkey inside your Flutter
  process. No TCP loopback, no daemon; starts in <100 ms on moto g35 5G
  and iPhone 12 Pro.
- Typed primitives: `HashKey`, `ListKey`, `SetKey`, `SortedSetKey`,
  `StreamKey`, `StringKey` with RESP-free `*Direct` fast paths
  (`HashKey.getAllDirect()` clocks ~30 µs per turn on iPhone 12 Pro).
- `VectorIndex` — HNSW, HNSW_SQ8 (NEON SDOT), HNSW_SQ8_RERANK,
  HNSW_F16. `addBatchDirect` + `searchDirect(..., efRuntime: ...)`
  are one-dart:ffi-crossing hot paths.
- `ChatAgent` + `ContextStore<T>` — observable `ValueNotifier`s
  (`messages`, `streaming`, `status`), tool loop with
  `maxToolIterations`, context window policies (`LastN`, `AllHistory`,
  `VectorRecall`), compaction.
- 5 LLM adapters: `LlamaCppClient` (GGUF via our patched llama.cpp),
  `LiteRtLmClient` (Google `.litertlm` — Android + iOS via our port),
  `FoundationModelsClient` (iOS 26+ Apple Intelligence),
  `OpenAICompatibleClient` (OpenAI / HF Router / Ollama / vLLM /
  Groq / …), `AnthropicClient` (Claude `/v1/messages` — distinct
  shape from OpenAI, auto-translated by the SDK).

## Install

The package is not on pub.dev yet. Consume it via a path dep:

```yaml
# pubspec.yaml
dependencies:
  dazzle_flutter:
    path: ../../sdk/flutter/dazzle_flutter    # adjust to your layout
```

Bootstrap the native artefacts before the first build (publishes the
Android AAR to a repo-local file-URL Maven, rsyncs the iOS Swift
sources + `libvalkey-server.a` into the plugin's `ios/Classes/vendored/`):

```bash
samples/_scripts/link_flutter.sh            # Android + iOS
samples/_scripts/link_flutter.sh android    # Android only
samples/_scripts/link_flutter.sh ios        # iOS only
```

## Minimum platform versions

| Platform | Target | Notes |
|----------|--------|-------|
| Android  | API 26+ | Ships `arm64-v8a` today. Add `ndk { abiFilters += listOf("arm64-v8a") }` in the app's `build.gradle.kts`. |
| iOS      | 17.0+   | Matches the `Dazzle.xcframework` deployment target. Set `platform :ios, '17.0'` in your Podfile. |

## Hello world

```dart
import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DazzleServer.shared.start();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp();
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: FutureBuilder<ChatAgent>(
        future: _buildAgent(),
        builder: (_, snap) => snap.hasData
            ? ChatView(agent: snap.data!)
            : const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );
  }
}

Future<ChatAgent> _buildAgent() async {
  final llm = OpenAICompatibleClient(
    baseURL: Uri.parse('https://api.openai.com/v1/'),
    model:   'gpt-4o-mini',
    apiKey:  const String.fromEnvironment('OPENAI_API_KEY'),
  );
  return DazzleServer.shared.chatAgent(
    threadId:     'session:42',
    llm:          llm,
    systemPrompt: 'You are a helpful on-device assistant.',
  );
}
```

## Persistence, in one paragraph

Every `ChatTurn` the agent produces lives in a Dazzle hash
(`agent:<threadId>:memory:<turnId>`) via `ContextStore<ChatTurn>`. On
cold boot the constructor scans the store and repopulates the
`messages` notifier in chronological order — your users see their
conversation again without you writing any bootstrap code.

## Running the samples

Three RAG patterns, Flutter-ported:

```
samples/chat-memory-flutter    zero RAG, persistent chat
samples/chat-iot-flutter       LLM + SortedSet tool (retrieve_anomalies)
samples/chat-kb-flutter        LLM + HNSW_SQ8 vector search tool
```

Run interactively:

```bash
cd samples/chat-memory-flutter
flutter run -d <device-id>
```

Run the headless automated test (scripts a `FakeLLMClient`, drives the
full ChatAgent + tool loop, writes `sample_test_<name>.json` into the
app's Documents dir):

```bash
samples/_scripts/test_flutter_android.sh   # all three on Android
samples/_scripts/test_flutter_ios.sh       # all three on iOS (release mode;
                                           # iOS blocks JIT for standalone debug)
```

Latest run reports under
`samples/_scripts/_test_results/chat-*_flutter_{android,ios}.json`.

## Swap the LLM adapter

Every sample imports its LLM from `samples/_shared/flutter/lib/src/llm_adapter.dart`.
The file has the five adapters in sequence — uncomment the one you
want, comment the rest, rebuild. Auto-detection runs first: if any
of `--dart-define=ANTHROPIC_API_KEY=…` / `OPENAI_API_KEY` / `HF_TOKEN`
is set at build time (or a runtime marker file lives at
`/data/local/tmp/dazzle_anthropic_key`, etc.), the adapter switches
to that cloud client without code edits.

```dart
// A — llama.cpp (any GGUF)
return LlamaCppClient.create(modelPath: ggufPath, temperature: 0.3);

// B — LiteRT-LM (.litertlm, Android + iOS via our port)
// return LiteRtLmClient.create(modelPath: litertPath, ...);

// C — Apple Foundation Models (iOS/macOS 26+)
// if (await FoundationModelsClient.isAvailable) return FoundationModelsClient();

// D — OpenAI-compatible (OpenAI, HF Router, Ollama, vLLM, …)
// return OpenAICompatibleClient(baseURL: Uri.parse('https://...'), model: '...');

// E — Anthropic (Claude /v1/messages)
// return AnthropicClient.create(
//   model:  'claude-haiku-4-5-20251001',
//   apiKey: const String.fromEnvironment('ANTHROPIC_API_KEY'),
// );
```

The `AnthropicClient` is a thin Dart shim over the native
`AnthropicBridge.{kt,swift}` and `AnthropicClient.{kt,swift}` — the
HTTP/SSE/JSON parsing lives in two files (Kotlin + Swift), not
four. Same `Stream<Delta>` / `Future<Completion>` surface as every
other adapter; tool-calling auto-translates to `DeltaToolCallStart`
/ `DeltaToolCallArgs`.

## Flutter Web

Flutter Web apps get a WebAssembly runtime (`dazzle.wasm`, ~236 KB)
that runs in-process inside the browser, persisted to the Origin
Private File System (OPFS). Same on-device promise the iOS / Android
targets deliver. The package's main library exports `DazzleWeb`,
`DazzleWebHash` and `DazzleWebVectorIndex` for this target.

**Setup** — add the loader script to your app's `web/index.html`,
**before** `flutter_bootstrap.js`:

```html
<script type="module">
  import dz from "assets/packages/dazzle_flutter/web/native/dazzle.js";
  globalThis.dazzleModule = dz;
</script>
```

Then in your Dart code:

```dart
import 'package:dazzle_flutter/dazzle_flutter.dart';

await DazzleWeb.initialize();
final hash = DazzleWeb.hash('chat:1');
hash.set('role', 'user');

final vec = DazzleWeb.vectorIndex('catalog');
vec.create(dim: 1536);
vec.add('product-1', embedding);                 // Float32List
final hits = vec.search(query, topK: 5);

await DazzleWeb.persist();                        // snapshot → OPFS
```

**Scope** (this beta): Hash KV + Vector index + OPFS snapshot.
**Not on web yet**: List / Set / SortedSet / Stream standalone
primitives, on-device LLM clients — those stay on iOS / Android /
Desktop.

## Flutter Desktop (Linux / macOS / Windows)

Native desktop targets use **`libdazzle_lite`** — the same C++
source as `dazzle.wasm`, compiled natively, exposed via `dart:ffi`.
Persistence to a regular file on disk (default
`<cwd>/.dazzle/snapshot.bin`, override with `snapshotPath:`). The
plugin declares `ffiPlugin: true` for `linux` / `macos` / `windows`,
so consuming apps get the right binary copied next to the runner
without a host C++ toolchain.

```dart
import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:path_provider/path_provider.dart';

final dir = await getApplicationSupportDirectory();
await DazzleDesktop.initialize(snapshotPath: '${dir.path}/dazzle.bin');

final hash = DazzleDesktop.hash('chat:1');
hash.set('role', 'user');

final vec = DazzleDesktop.vectorIndex('catalog');
vec.create(dim: 1536);
vec.add('product-1', embedding);
final hits = vec.search(query, topK: 5);

await DazzleDesktop.persist();
```

The API surface mirrors `DazzleWeb` exactly — apps that target
both Web and Desktop share the same data layer:

```dart
import 'package:flutter/foundation.dart' show kIsWeb;

if (kIsWeb) {
  await DazzleWeb.initialize();
} else {
  await DazzleDesktop.initialize();
}
```

**Snapshot binary format is identical** between Web (WASM) and
Desktop (native) builds — a snapshot saved by a Flutter Web app
loads byte-for-byte on Flutter Desktop and on a C++ server linking
the same `libdazzle_lite`.

**Scope** (this beta): same as Web — Hash + Vector + snapshot. The
full Valkey embedded surface (Lists / Streams / SortedSets / Lua /
pub-sub) is on the roadmap; for now apps that need those primitives
on desktop should fall back to a sidecar via the
[`Dazzle.NET`](./dotnet-quickstart.md) NuGet package.

## Reporting an issue

GitHub: https://github.com/IvanAliaga/dazzle-sdk/issues — include the
failing `flutter analyze` output + the JSON report from
`samples/_scripts/_test_results/` if the sample harness surfaces it.
