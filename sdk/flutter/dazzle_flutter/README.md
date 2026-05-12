# dazzle_flutter

**Dazzle SDK for Flutter — embedded database + vector search + ChatAgent
for on-device LLM apps.** Links the same `libdazzle.so` (Android) and
`Dazzle.xcframework` (iOS) the native Kotlin and Swift SDKs use, so
every platform sees identical behaviour and the same benchmark profile.

- **9× faster vector search** than SQLiteAI's commercial `sqlite-vector`
  at matching recall (moto g35 5G, dim=384, N=10 000) — same numbers
  as the native SDK because it's the same binary.
- **Dart FFI hot path** — `Hash.getAllDirect()`, `SortedSetKey
  .rangeByScoreDirect()`, `VectorIndex.searchDirect()` skip RESP, match
  the sub-50 µs latencies the native apps measure.
- **5 LLM adapters**: `LlamaCppClient` (our patched llama.cpp fork
  via dart:ffi + Isolate + `NativeCallable.listener`),
  `LiteRtLmClient` (method channel to the native Kotlin/Swift adapter),
  `FoundationModelsClient` (iOS 26+ via method channel),
  `OpenAICompatibleClient` (pure Dart HTTP),
  `AnthropicClient` (method channel to the native Kotlin/Swift
  `AnthropicClient` — distinct shape from OpenAI auto-translated by
  the SDK).

## Status

- **F1 — primitives + server lifecycle** ✅
- **F2 — `VectorIndex`, `ContextStore<T>`, `ChatAgent` Dart core** ✅
- **F3 — the 5 LLM adapters** ✅
- **F4 — `chat-memory` / `chat-iot` / `chat-kb` example Flutter apps** ✅
  (3/3 PASS on Moto G35 5G + iPhone 12 Pro)
- **F5 — pub.dev publish** ✅ ([`dazzle_flutter` on pub.dev](https://pub.dev/packages/dazzle_flutter)) — CI + DocC-equivalent docs next.

## Quickstart

```yaml
# pubspec.yaml
dependencies:
  dazzle_flutter: ^1.0.0-beta.6
```

```dart
import 'package:dazzle_flutter/dazzle_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DazzleServer.shared.start();

  final dazzle = DazzleServer.shared.client();
  final hash = dazzle.hash('agent:chat:turn_1');
  hash.set('role', 'user');
  hash.set('text', "What's the weather in Lima?");

  // Fast path — RESP-free snapshot cache read, ~30 µs on A14.
  final turn = hash.getAllDirect();
  print(turn);
}
```

## Architecture

```
┌──────────────────────────────┐
│  Dart                        │
│  DazzleServer.shared.start() │ ───► method channel ───► native DazzleServer
│                              │                          (Kotlin or Swift)
│  hash.set("f","v")           │ ───► dart:ffi ──► libdazzle C symbols
│  hash.getAllDirect()         │ ───► dart:ffi ──► dazzle_snapshot_hgetall_typed
│  llm.stream(messages)        │ ───► Isolate + NativeCallable.listener
│                              │      (zero-copy tokens from llama.cpp)
└──────────────────────────────┘
```

Why two paths: server start is a multi-step ceremony (spawn worker
thread, run `valkey-main`, wait for `Server initialized`, attach the
in-process mirror) that already exists in Kotlin / Swift. Re-implementing
it in Dart would add bugs and drift. All *data* operations skip the
method channel to avoid its platform-side JSON serialisation.

## EventChannel bridge invariants (LiteRT / FoundationModels / Anthropic)

The three native-backed LLM bridges
(`LiteRtBridge.kt`, `AnthropicBridge.{kt,swift}`,
`FoundationModelsBridge.swift`) all follow the same rules — diverging
breaks multi-turn streaming silently. If you add a new bridge, copy
this template:

1. **Per-subscription Job/Task tracking.** Never use a single
   `activeJob` / `activeTask` member field. Each `onListen` mints
   its own entry in `tasksBySubId` / `jobsBySubId` and
   self-deregisters on completion.
2. **`onCancel` is a no-op.** Flutter's async `onCancel` lands AFTER
   the next turn's `onListen` and would otherwise cancel the new
   coroutine / Task. `dispose()` cancels anything still in-flight.
3. **End-of-stream is a `{"type": "end"}` frame, never
   `events(FlutterEndOfEventStream)` / `sink.endOfStream()`.** Either
   call permanently kills the EventChannel for every subsequent turn.
4. **Each frame carries a `streamId` cookie** the dart-side shim
   minted on `stream()` entry; the shim drops frames whose
   `streamId` doesn't match. Defends against the EventChannel buffer
   replaying the previous turn's `type: "end"` to a fresh listener.

See [`samples/PROVIDERS.md`](../../../samples/PROVIDERS.md) for the
full debug story behind each invariant.

## Flutter Web (1.0.0-beta.6+)

Dazzle ships a WebAssembly runtime that runs HNSW vector search and a hash
KV **in-process inside the browser**, with persistence backed by the
Origin Private File System (OPFS). No remote server, no proxy — same
on-device promise the iOS / Android targets deliver, on the web.

**Scope** (this beta): Hash KV + Vector index + OPFS snapshot.
**Not yet on web**: List / Set / SortedSet / Stream standalone primitives,
on-device LLM clients (LlamaCpp / LiteRT-LM / FoundationModels) — those
stay on iOS / Android / Desktop.

### Setup

1. The package ships `web/native/dazzle.wasm` (~236 KB) +
   `web/native/dazzle.js` (~68 KB) as Flutter assets. They are referenced
   from `pubspec.yaml` and copied into the build automatically.

2. Add the loader script to your app's `web/index.html`, **before** the
   `<script src="flutter_bootstrap.js">` line:

   ```html
   <script type="module">
     import dz from "assets/packages/dazzle_flutter/web/native/dazzle.js";
     globalThis.dazzleModule = dz;
   </script>
   ```

3. In your Dart code:

   ```dart
   import 'package:dazzle_flutter/dazzle_flutter.dart';

   await DazzleWeb.initialize();          // loads WASM + restores OPFS
   final hash = DazzleWeb.hash('chat:1');
   hash.set('role', 'user');
   hash.set('text', 'hello');

   final vec = DazzleWeb.vectorIndex('catalog');
   vec.create(dim: 1536);
   vec.add('product-1', embedding);        // Float32List
   final hits = vec.search(query, topK: 5);

   await DazzleWeb.persist();              // snapshot → OPFS
   ```

### OPFS quota

OPFS is per-origin and persistent across reloads. Quota is browser-managed
(typically tens of GiB). For multi-user apps, pass `opfsFileName:` to
`initialize()` so each user's snapshot lands in a separate file.

## Documentation

- Quickstart + Metro / Pod setup: [`docs/sdk/flutter-quickstart.md`](../../../docs/sdk/flutter-quickstart.md)
- API contract (cross-platform surface): [`docs/sdk/API_CONTRACT.md`](../../../docs/sdk/API_CONTRACT.md)
- LLM provider matrix + live verification: [`samples/PROVIDERS.md`](../../../samples/PROVIDERS.md)
- Roadmap: [`docs/ROADMAP.md`](../../../docs/ROADMAP.md)

## License

Apache-2.0, same as the rest of Dazzle.
