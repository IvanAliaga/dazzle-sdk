# Changelog

All notable changes to the Dazzle SDK. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it hits
`1.0.0`; pre-release builds use `1.0.0-beta.N` suffixes.

## 1.0.0-beta.3 — 2026-04-24

### Added

- **Flutter plugin — `sdk/flutter/dazzle_flutter/`.** Same embedded
  Valkey + snapshot cache + HNSW vector search + ChatAgent runtime the
  native Android / iOS SDKs ship, consumed from Dart via dart:ffi on
  the hot path (`HashKey.getAllDirect`, `SortedSetKey.rangeByScoreDirect`,
  `VectorIndex.searchDirect`) and via a method channel only for
  lifecycle. Four LLM adapters:
  - `LlamaCppClient` — Isolate worker + `NativeCallable.listener`
    pattern for zero-copy C→Dart token streaming.
  - `LiteRtLmClient` — Android: plugin Kotlin bridge
    (`LiteRtBridge.kt`) instantiates the native
    `dev.dazzle.sdk.edge.LiteRtLmClient` under int handles,
    streams Delta events through `dev.dazzle.flutter/litertlm.tokens`.
  - `FoundationModelsClient` — iOS 26+ Swift bridge
    (`FoundationModelsBridge.swift`) ships Apple Intelligence
    tokens through `dev.dazzle.flutter/foundation.tokens`.
  - `OpenAICompatibleClient` — pure Dart + package:http with SSE
    streaming.
  - `ChatAgent.VectorRecallWindow` now does real retrieval: lazily
    opens an HNSW_SQ8 index keyed `agent:<thread>:idx`, indexes
    every persisted ChatTurn through an optional `Embedder`
    closure, and prepends top-k semantically similar older turns to
    the LastN window each send().
  - Three samples — `chat-memory-flutter`, `chat-iot-flutter`,
    `chat-kb-flutter` — run **6/6 PASS** on moto g35 5G + iPhone 12
    Pro via `samples/_scripts/test_flutter_{android,ios}.sh`.
- **React Native package — `sdk/react-native/dazzle-react-native/`.**
  Same contract as the Flutter plugin, TypeScript-typed. Hot-path
  now uses `isBlockingSynchronousMethod` sync bridges — `dazzleCommandSync`
  / `snapHGetAllSync` / `snapZRangeByScoreSync` / `snapSMembersSync`
  / `snapGetSync` on both Android (Kotlin) and iOS (ObjC++/Swift) —
  **5-10× perf vs the async bridge (~15 µs vs ~100 µs per call)**.
  The TS wrappers auto-detect the sync variants and fall back to the
  async path when absent. LLM adapters:
  - `LlamaCppClient` — native Kotlin + Swift bridges wired through
    `DazzleLLMBridges` (iOS) + direct NativeModule (Android), with
    `NativeEventEmitter` streaming.
  - `FoundationModelsClient` — iOS 26+ live through the same bridge.
  - `LiteRtLmClient` — opt-in today: the Kotlin 2.3 metadata of
    `litertlm-android:0.10.0` is incompatible with the Kotlin 2.1
    RN 0.85 toolchain. Shim documented in docs/ROADMAP.md; iOS
    wrapping tracked separately via the SPM `DazzleLiteRTLM` target.
  - `OpenAICompatibleClient` — pure TS + `fetch` + SSE.
  - `ContextWindow.vectorRecall` — same retrieval shape as Flutter.
  - Three samples — `chat-memory-rn`, `chat-iot-rn`, `chat-kb-rn` —
    run PASS on moto g35 5G, iPhone 12 Pro via
    `samples/_scripts/test_rn_{android,ios}.sh`.
- **Native linking helper scripts.** `samples/_scripts/link_flutter.sh`
  + `link_rn.sh` bootstrap the Android AAR (into a repo-local file-URL
  maven repo — no external publish) and rsync the iOS Swift sources +
  `libvalkey-server.a` into each plugin's pod dir. Both are run once
  after cloning + whenever the native SDK changes.
- **`samples/` — three production-shaped demos**, iOS + Android, each
  swappable across all four LLM adapters (`LlamaCppClient` /
  `LiteRtLmClient` / `FoundationModelsClient` /
  `OpenAICompatibleClient`) via one shared file per platform:
  - `chat-memory` — pure conversational history, no RAG
  - `chat-iot` — tool calling + `SortedSetKey.rangeByScore`
    retrieval over a bundled 30-window sensor dataset
  - `chat-kb` — vector search (HNSW_SQ8) over a bundled 30-row
    Dazzle FAQ corpus with a zero-dep `miniEmbed` hash embedder
- **Headless e2e harness** (`SampleTestRunner.{swift,kt}`) — every
  sample ships a `SAMPLE_TEST=1` mode that drives a scripted flow
  through the real ChatAgent + tool loop with `FakeLLMClient`, writes
  a JSON report, exits cleanly. **6/6 PASS** on moto g35 5G + iPhone
  12 Pro. `samples/_scripts/test_{ios,android}.sh` automate the full
  install-run-pull-validate cycle.
- **Vector benchmark vs SQLiteAI's commercial `sqlite-vector`
  extension**, not just the OSS `sqlite-vec`. Android: `dazzle-sq8`
  is **9× faster** at matching recall; `dazzle-sq8+rerank` is 5.3×
  faster AND higher recall (0.998 vs 0.993). iOS links the same
  xcframework (sqlite-vector `0.9.95`) but Apple's system libsqlite3
  deprecated process-global auto extensions in iOS 12, so the iOS
  row gracefully skips to `sqlite-vec` brute-force as the reference.
- **Hardcore vector sweep** at BGE-large / OpenAI-3-large dims on
  moto g35 5G: `dazzle-sq8` is 11.4× faster than sqlite-vector-ai at
  `dim=768 N=10 k` and 12.9× faster at `dim=1024 N=10 k`. The gap
  *widens* with dim because NEON SDOT scales linearly while
  sqlite-vector-ai's per-row overhead stays constant.
  (Full benchmark tables released alongside the paper.)
- **iOS storage + vector bench** on iPhone 12 Pro (A14): `dazzle-sq8`
  498× faster than sqlite-vec, `dazzle-precompute` at 33 µs P50 on
  the SortedSet retrieval pattern. (Full iOS table released
  alongside the paper.)
- **README: Context window section** — explains what Dazzle promises
  ("unbounded history + semantic retrieval") vs what LLM vendors
  promise ("1 M tokens in the prompt"), with a per-adapter matrix of
  realistic on-device limits and recommended `ContextWindow`
  policies.

### Fixed

- **Snapshot cache: silent truncation on long members**. The fast-path
  typed readers (`dazzle_snapshot_hgetall_typed`,
  `dazzle_snapshot_smembers_typed`,
  `dazzle_snapshot_zrange_by_score_typed`,
  `dazzle_snapshot_get_string_typed`) write field names + values into
  fixed-size buffers (`SNAP_KEY_LEN=128`, `SNAP_VAL_LEN=256`).
  Oversize members (e.g. a 200-byte JSON blob in a ZSET for the
  `dazzle-precompute` pattern) were `strncpy`-truncated, so readers
  got back corrupt half-payloads.

  The end-to-end sample test surfaced this: `samples/chat-iot`'s
  `retrieve_anomalies` tool decoded 11 members from the snapshot,
  every decode failed at byte 127, the tool returned `[]`, the LLM
  had nothing to answer with.

  Fix: `snap_set_field` now detects overflow before writing and marks
  the entry `valid=0` + **sticky `poisoned=1`**. Subsequent reads
  miss and fall back to the RESP path (no length limit). The new
  `poisoned` flag prevents `snap_find_or_create_in_bucket` from
  reclaiming the slot for a later short-member write, which would
  otherwise surface partial keyspace data. `DEL`/`UNLINK` clears
  poison so a fresh `SET`/`HSET`/`ZADD` re-enters the fast path.
  `SnapEntry` grows by 4 bytes (≈1 KB across 256 cache slots).

## 1.0.0-beta.4 — 2026-04-24

### Added — `AnthropicClient` (5th LLM adapter, all four stacks)

First-class support for Anthropic's Messages API
(`POST /v1/messages`) — distinct from `OpenAICompatibleClient`
because Anthropic uses its own shape: `system` is a top-level
field (not a `messages[]` entry), tool calls / tool results are
**content blocks** inside `content` arrays, schemas live under
`input_schema`, and the SSE stream uses `content_block_*` /
`message_*` events instead of OpenAI's unified `delta` chunks.
The SDK handles every mapping; the agent code is identical
across providers.

```kotlin
val claude = AnthropicClient(
    model     = "claude-haiku-4-5-20251001",
    apiKey    = System.getProperty("dazzle.anthropic_key", ""),
    maxTokens = 1024,
)
```

```swift
let claude = AnthropicClient(
    model:     "claude-haiku-4-5-20251001",
    apiKey:    ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
    maxTokens: 1024)
```

```dart
final claude = await AnthropicClient.create(
  model:  'claude-haiku-4-5-20251001',
  apiKey: const String.fromEnvironment('ANTHROPIC_API_KEY'),
);
```

```ts
const claude = await AnthropicClient.create({
  model:  'claude-haiku-4-5-20251001',
  apiKey: process.env.ANTHROPIC_API_KEY!,
});
```

Implementation footprint — HTTP/SSE/JSON parsing lives in
**two files only**, not four:

- `sdk/android/src/main/java/dev/dazzle/sdk/edge/AnthropicClient.kt`
  (382 lines, `HttpURLConnection` + `org.json`, zero external deps)
- `sdk/ios/Sources/AnthropicClient.swift`
  (389 lines, `URLSession`, zero deps)

Flutter and React Native are **thin bridges** over those:

- `sdk/flutter/.../AnthropicBridge.{kt,swift}` — Method/EventChannel
  to the native client.
- `sdk/flutter/.../lib/src/edge/anthropic_client.dart` — Dart shim.
- `sdk/react-native/.../src/edge/anthropicClient.ts` — TS shim over
  `NativeModule` + `DeviceEventEmitter`.
- `sdk/react-native/.../DazzleReactNativeModule.kt` — Kotlin
  NativeModule that delegates to `AnthropicClient.kt`.

If the API changes, **edit two files, not four**. Same surface
every other LLMClient exposes (`complete()` / `stream()` /
`close()` / `modelId`); tool-calling auto-translates to
`Delta.toolCallStart` / `Delta.toolCallArgs`.

Each `LLMAdapter` template (Android Kotlin, iOS Swift, Flutter
Dart, the three RN samples) has a labelled `─── E ───` block
with the Anthropic recipe behind a comment + auto-detection from
the runtime env (`ANTHROPIC_API_KEY` for iOS native and
`SIMCTL_CHILD_*`; `--dart-define=ANTHROPIC_API_KEY=…` or a
`/data/local/tmp/dazzle_anthropic_key` marker file for Flutter;
`process.env.ANTHROPIC_API_KEY` / NativeModule env bridge for RN).

`samples/PROVIDERS.md` adds an Anthropic section + the captured
"Live verification matrix" with the four end-to-end smokes.

### Added — RN wrapper deduplication

The three RN wrappers (`LlamaCppClient` / `FoundationModelsClient`
/ `AnthropicClient`) used the same DeviceEventEmitter queue +
waiter + listener boilerplate (~50 lines each). Extracted to
`sdk/react-native/.../src/edge/_nativeLLMStream.ts` exposing a
`runNativeStream(spec, payload)` async generator. Each wrapper
now declares its event name + start method and otherwise focuses
on payload encoding. **Future native-backed RN providers add
~30 lines instead of ~150.**

### Fixed — three EventChannel bridge bugs (Flutter)

Three subtle race / lifecycle bugs surfaced when running multi-
turn against Anthropic on the Flutter iOS simulator. Each one
alone produced a chat reply with `last_assistant_text: ""`. Fixed
all three; **applied preventively to every EventChannel bridge**
in the plugin (Anthropic on both platforms, LiteRT-LM on Android,
FoundationModels on iOS) since the same patterns would surface
the moment those bridges saw multi-turn flow.

1. **`onCancel` lands AFTER the next `onListen`.** When turn N's
   dart-side subscription closes, Flutter posts an async
   `onCancel` to the platform thread. The agent then issues turn
   N+1, whose `onListen` lands first. With a single `activeTask`
   /`activeJob` member, the late `onCancel` ends up cancelling
   turn N+1's task — its `URLSessionTask` /
   `okhttp.Call`-equivalent dies with `NSURLErrorCancelled`.
   *Fix:* per-subscription Task/Job tracking
   (`tasksBySubId` / `jobsBySubId`) with self-deregistration;
   `onCancel` is now a no-op (let tasks complete naturally;
   `dispose()` cancels anything still in-flight on plugin
   detach).

2. **`FlutterEndOfEventStream` / `sink.endOfStream()`
   permanently kills the channel.** Either tells Flutter "this
   `EventChannel` is permanently closed", which means *every*
   future `onListen` is dropped silently. *Fix:* send a plain
   `{"type": "end"}` frame so the dart-side `StreamController`
   closes; never call the permanent-close API for a per-turn
   stream.

3. **EventChannel buffer can replay the previous turn's last
   frame.** Even with the two fixes above, the new subscription
   occasionally received the *previous* turn's `type: "end"`
   frame as its first event and closed its controller before any
   real chunk arrived. *Fix:* the dart-side shim mints a
   `streamId` cookie on every `stream()` call, the bridge tags
   every emitted frame with that cookie, and the shim drops
   anything whose `streamId` doesn't match.

### Fixed — Flutter iOS sim "unsupported Swift architecture"

The plugin podspec already excluded `x86_64` from the simulator
slice of the *plugin* via `EXCLUDED_ARCHS`, but didn't propagate
that to the consumer app. On Apple Silicon Macs the host app
would still build the `x86_64` sim slice, hit a Swift header
generated only with the `__arm64__` branch, and fail with
`#error unsupported Swift architecture`. Added
`s.user_target_xcconfig` to push the same exclusion to consumers.

### Fixed — `OpenAICompatibleClient` SSE on RN (whatwg-fetch)

React Native's `fetch` polyfill returns `resp.body === null` for
chunked-encoding 200 responses — its `ReadableStream` machinery
isn't shipped. The TS client now detects that case and falls
back to `await resp.text()` + a buffered SSE parser, so HF
Router / Groq / OpenAI streaming work end-to-end on RN.

### Verified — live end-to-end against `api.anthropic.com`

Full matrix below, all against real billing on Anthropic Haiku
4.5 (`claude-haiku-4-5-20251001`):

| Stack                   | Sample                | Result |
|-------------------------|-----------------------|--------|
| RN Android (Moto G35)   | chat-kb-rn            | PASS — 5 turns, 2 tool round-trips, assistant reply quotes literal corpus numbers (76×, 498×, "A14 Bionic", …) |
| iOS native sim          | DazzleChatMemory      | PASS — 4 turns, multi-turn memory works |
| Flutter Android (Moto)  | chat-memory-flutter   | PASS — post bridge thread fix |
| Flutter iOS sim         | chat-memory-flutter   | PASS — post 3 bridge fixes |

The `chat-kb-rn` reply contains the **literal numbers from the
on-device FAQ corpus**, proving the full path works:

```
RN JS  →  NativeModule (Kotlin)  →  libdazzle.so
                                       ├─ Valkey + HNSW_SQ8 (search_kb tool)
                                       └─ embedder (NEON SDOT)
                →  AnthropicClient.kt  →  HTTPS POST /v1/messages
                →  SSE stream parsed   →  Delta(text + tool_use)
                →  ChatAgent           →  tool exec (vector search)
                →  next /v1/messages   →  final synthesis
```

### Roadmap — `docs/plans/05-http-clients-to-jsi-cpp.md`

Captured the architectural option of unifying *all* HTTP-based
LLM clients (`OpenAICompatibleClient` + `AnthropicClient` +
future Cohere/Gemini/etc.) into a single C/C++ core inside
`libdazzle.so` + JSI on RN + `dart:ffi` on Flutter. Deferred
until the next HTTP provider lands so the migration cost is
amortised.

## Unreleased

_(No unreleased changes — next tag target is `1.0.0-beta.5`.)_

### Fixed — RESP-free path extended to SET / SORTED-SET / STRING (Phase 2)

Phase 7 capped RESP on the HGETALL path. Phase 2 generalises the same
idea to the other primitives ContextStore touches in its hot loops —
tag index (`SMEMBERS`), time index (`ZRANGEBYSCORE`) and string
metadata (`GET`). Snapshot cache now carries a per-entry `type` so
the same SnapEntry storage can serve hash, set, zset and string
reads without RESP encoding on the C side or `RespParser` walking
on the client side.

A/B on moto g35 5G, 5 000 iterations each:

```
Phase 7  HGETALL       : 367.27 → 13.87 µs  ( 26.48×)
Phase 2  SMEMBERS      : 441.86 → 15.13 µs  ( 29.20×)
Phase 2  ZRANGEBYSCORE : 664.30 → 34.15 µs  ( 19.45×)
Phase 2  GET           : 242.12 →  9.15 µs  ( 26.47×)
```

Four hot reads now bypass RESP entirely. Combined impact on a
typical ChatAgent turn (20 × get + 1 × byTimeRange + 2 × byTag):
previously ≈ 8 ms of pure RESP overhead, now ≈ 0.3 ms.

Changes
- `core/transport/dazzle_transport.c`:
  - `SnapEntry.type` field (`SNAP_TYPE_{HASH,SET,ZSET,STRING}`),
    same SnapField[] storage reused.
  - `mirror_write` now recognises `SADD` / `SREM` / `ZADD` / `ZREM` /
    `SET` / `HDEL` / `DEL` / `FLUSHDB` / `FLUSHALL`.
  - New typed readers: `dazzle_snapshot_smembers_typed`,
    `dazzle_snapshot_zrange_all_typed`,
    `dazzle_snapshot_zrange_by_score_typed`,
    `dazzle_snapshot_get_string_typed`.
  - Existing hash readers filter by `type == SNAP_TYPE_HASH` so a
    key repurposed as a set never returns stale hash pairs.
- `core/platform/dazzle_ios.h`: four new entry points.
- `sdk/android/src/main/cpp/dazzle_jni.c`: three new JNI wrappers
  (`nativeDirectSmembers`, `nativeDirectZrangeByScore`,
  `nativeDirectGetString`).
- Kotlin: `SetKey.membersDirect`, `SortedSetKey.rangeByScoreDirect`,
  `StringKey.getDirect`. All auto-fall-back to their RESP variants on
  snapshot miss.
- Swift: same three methods mirrored in `DazzlePrimitives.swift`.
- `DazzleContextStore` on both platforms: `byTag` / `byTags` /
  `byTimeRange` now invoke the typed variants.

Tests
- `Phase2FastPathBenchmarkTest` runs the three A/Bs on every
  invocation; logcat tag `Phase2Bench`. Paired with the
  `Phase7Bench` smoke from the prior commit, any future regression
  shows up with a single `adb logcat -s Phase2Bench Phase7Bench`.

### Fixed — ContextStore read regressed ~26× vs baseline; Phase 7 restores it

`ContextStore.get()` went through `HashKey.getAll()` when it was
unified on `commandTyped(HGETALL)`, which means every record read
paid the full RESP round-trip even though Dazzle is embedded and
nobody outside the SDK ever consumes that RESP. On records hot in
the in-process snapshot cache that round-trip dominated.

A/B benchmark on moto g35 5G, 5 000 iterations, same record hot in
the snapshot:

```
getAll()        (RESP path)       : 367.27 µs/call
getAllDirect()  (snapshot typed)  :  13.87 µs/call
                                    ─────────
                                    26.48× speedup
```

Changes
- New `dazzle_snapshot_hgetall_typed` in
  `core/transport/dazzle_transport.c`. Walks the snapshot entry
  directly, returns malloc'd `(k, v)` pairs. No RESP generated on
  the C side, no `RespParser` walk on the client side.
- Exposed through `dazzle_ios.h` (so Swift sees it in `DazzleC`)
  and `nativeDirectHgetall` in `dazzle_jni.c` (so Kotlin sees an
  interleaved `String[]`).
- New `HashKey.getAllDirect()` on both Kotlin and Swift. Falls
  back to `getAll()` on a snapshot miss so callers can use it
  unconditionally.
- `DazzleContextStore.get()` (both platforms) switched to the
  new fast path — restores the memory-hot-record read latency
  that the paper measured before the ContextStore refactor.

Why this matters — a typical ChatAgent turn reads 20 prior
ChatTurns from `ContextStore` before calling the LLM. With the
RESP path that cost ≈ 7.3 ms of pure parsing per turn; with the
typed path it's ≈ 0.28 ms. The LLM inference is still the
bottleneck, but every µs we save before it is a µs the UI is
unblocked.

### Added — `FoundationModelsClient` (iOS 26+ / macOS 26+, Apple Intelligence)

- New `LLMClient` backed by Apple's on-device 3 B-parameter model
  shipped with Apple Intelligence. Free at runtime — no weights to
  download, no API key, no cloud round-trip. Gated on iOS 26+ /
  macOS 26+ via `@available`; older OSes compile with the
  `FoundationModelsClientUnavailable` placeholder.

  ```swift
  guard FoundationModelsClient.isAvailable else { /* fallback */ }
  let llm = FoundationModelsClient()
  let agent = try DazzleEdge.chatAgent(llm: llm)
  ```

- Streams via Apple's `ResponseStream<String>` — we diff successive
  `Snapshot.content` snapshots into incremental text deltas and
  route them through the existing `ToolCallParser`, so Gemma /
  Llama / Qwen tool-call dialects work even on Foundation Models.
- `isAvailable` reflects `SystemLanguageModel.default.availability
  == .available`. Consumers who need to distinguish "model
  downloading" / "device ineligible" read the raw enum directly.

### Added — `LlamaCppClient` with embedded llama.cpp (both platforms)

- llama.cpp is now shipped **inside** `libdazzle.so` (Android) and
  `Dazzle.xcframework` (iOS). A consumer loads any GGUF model —
  Gemma 2/3, Llama 3.x, Qwen 2.5, Phi-4, DeepSeek, Mistral — via:

  ```kotlin
  val llm = LlamaCppClient(modelFile = File(".../qwen2.5-1.5b-Q4_K_M.gguf"))
  val agent = DazzleEdge.chatAgent(context, llm = llm)
  ```

  iOS Swift mirror is identical. No extra SPM / Maven dependency.

- Pinned to llama.cpp `b4120` (reproducible builds). Local
  workarounds / upstream-unresolved bug fixes live under
  `versions/llama_cpp/patches/` and apply automatically on every
  clean build — same pattern as `versions/v9/patches/` for Valkey.
- New `core/platform/dazzle_llama.{h,cpp}` — minimal plain-C
  surface (`dazzle_llama_backend_init`, `_load_model`,
  `_new_context`, `_generate`, `_free_*`). Exposed through DazzleC
  modulemap on iOS and `LlamaNative` JNI on Android.
- Tool-calling reuses the existing `ToolCallSyntax` /
  `ToolCallParser` pipeline, so Gemma / Llama / Qwen tool output
  is turned into `Delta.ToolCallStart` + `Delta.ToolCallArgs`
  without extra configuration.
- Artifact size — Android `libdazzle.so` goes from 14 MB to 32 MB
  (unstripped debug); released / stripped ≈ 16 MB. iOS
  `libvalkey-server.a` 11 MB → 13 MB.
- Tests — 4 smoke tests on `moto g35 5G` validate backend init +
  missing-file handling + null-handle safety without requiring a
  real GGUF file. Real-inference smoke test documented for manual
  device validation.

### Added — `OpenAICompatibleClient` on both platforms

- New `LLMClient` that speaks the OpenAI `chat/completions` wire
  format. A single adapter covers OpenAI itself, Azure OpenAI,
  Groq, Together AI, **HuggingFace Inference Providers**
  (`router.huggingface.co/v1`), **Ollama local**
  (`http://10.0.2.2:11434/v1` from the Android emulator or
  `http://localhost:11434/v1` on the host), vLLM, LM Studio,
  OpenRouter, or any FastAPI proxy.
- Native tool-call emission — `Delta.ToolCallStart` +
  `Delta.ToolCallArgs` are parsed straight from the `tool_calls`
  deltas in the SSE stream; no `ToolCallParser` needed since the
  wire format is already structured.
- Zero external deps: Android uses `HttpURLConnection` + `org.json`
  (both in the platform SDK); iOS uses `URLSession` + Codable /
  `JSONSerialization`. No OkHttp, no Alamofire, no
  kotlinx-serialization added to the AAR.
- Tests — parallel pairs on both platforms. Android: in-process
  `ServerSocket` HTTP/1.1 mock; 7/7 pass on `moto g35 5G`. iOS:
  `URLProtocol` interceptor driven from `URLSessionConfiguration`.

### Changed — in-process is now the default (breaking: `tcpEnabled`)

- `DazzleConfig.tcpEnabled` default flipped from `true` to `false`.
  The SDK has always routed every `ChatAgent`, `ContextStore` and
  primitive call through the in-process JNI pipe; keeping a loopback
  listener open by default was a leftover from the pre-directCommand
  era and caused every integrating app to reserve port 6379 without
  needing it. Flip to `true` explicitly when you want to attach
  `redis-cli` / benchmarks for debugging.
- New patch `versions/v9/patches/05_no_listener.patch` — upstream
  Valkey aborts in `initListeners()` when `listen_fds == 0` with
  "Configured to not listen anywhere, exiting.". On Android / iOS
  builds this check is now a log-and-continue so the fake-client
  path (`CLIENT_ID_CACHED_RESPONSE` wired up in `dazzle_direct_init`)
  can serve every directCommand without needing any socket.
- Android demo `MainActivity` — the "Send Command" button now
  dispatches through `DazzleServer.directCommand(*args)` instead of
  a loopback TCP socket, matching the path the rest of the SDK
  takes.
- Status text reads `"Valkey: Running (in-process)"` when no TCP
  listener is active.

### Added — Chat demos on both platforms

- iOS: new `ChatView` (SwiftUI) wired as a third tab in `DazzleDemo`
  via `DazzleEdge.chatAgent(...)` + a small in-app `EchoLLMClient`.
  Streams the "typing" bubble letter-by-letter, auto-scrolls on new
  messages, persists history under thread id `demo-default`.
- Android: new `ChatActivity` (Compose + Material3) wired from the
  Views-based `MainActivity` via an "Open Chat" button. Same Agent
  contract, same EchoLLMClient shape — swap for `LiteRtLmClient` to
  drive a real Gemma/Llama/Qwen model without touching the UI code.
- iOS demo `project.yml` now targets iOS 17 (the SDK uses
  `@Observable` / `NavigationStack` / `Duration`) and links `libc++`
  so the HNSW/SQ8 C++ objects resolve at link time.

### Added — Release tooling for SHA256 pinning

- Internal `pin_model_hashes.py` utility: a maintainer downloads
  the three shipped `.litertlm` models once and runs the script
  to compute streaming SHA-256 digests and rewrite the `sha256`
  fields in `docs/sdk/edge_models.json` plus both
  `ModelManifest.{kt,swift}` projections atomically. `--dry-run`
  prints the digests without writing. (The pinning script lives
  with the paper-companion repo.)

### Added — Tool-call parsing in `LiteRtLmClient` (both platforms)

- `LiteRtLmClient` now parses the three mainstream on-device
  tool-call dialects when the caller passes a non-empty `tools`
  list: Gemma (`<tool_call>…</tool_call>`), Llama 3.1 / 3.2
  (`<|python_tag|>…<|eom_id|>`), and Qwen 2.5 (Gemma delimiters +
  Qwen prompt framing).
- New `ToolCallSyntax { auto, gemma, llama32, qwen25 }` enum — the
  adapter picks the dialect from the filename when `auto`.
- Streaming output is piped through a new `ToolCallParser` that
  emits `Delta.toolCallStart` / `Delta.toolCallArgs` events for
  tool blocks and forwards plain text verbatim; `complete()`
  assembles a `Completion.toolCalls` when the model invoked at
  least one tool.
- Parallel unit tests on both platforms cover chunk-boundary
  splits, malformed JSON fallbacks, multi-call streams, and
  dialect-specific prompt renderers.

### Added — VectorIndex iOS paridad (quantised + direct fast paths)

- iOS `VectorIndex` now exposes `hnswSq8`, `hnswSq8Rerank`, and
  `hnswF16` algorithms — same semantics as the Android SDK. Requires
  `metric = .cosine`.
- iOS fast-path methods `addDirect(id:vector:)`,
  `addBatchDirect(ids:vectors:)`, `searchDirect(query:k:efRuntime:)`
  bypass RESP / base64 and go straight to hnswlib. Identical signature
  to the Android JNI variants.
- `sdk/ios/build.sh` now compiles `simsimd_lib.c` alongside
  `valkeysearch_module.cc` with `DAZZLE_VECTOR_SIMSIMD` and
  `-march=armv8.2-a+fp16+dotprod`, so the NEON SDOT / FMLA-f16
  kernels ship inside the iOS xcframework.

### Changed — internal C bridge layout

- `sdk/android/src/main/cpp/valkeysearch_module.cc` now carries a
  plain-C surface (`dazzle_vs_create_sq8`, `dazzle_vs_create_f16`,
  `dazzle_vs_open_handle`, `dazzle_vs_add_direct`,
  `dazzle_vs_add_batch_direct`, `dazzle_vs_search_handle`,
  `dazzle_vs_search_direct`, `dazzle_vs_free_id`). Android JNI
  symbols (`Java_dev_dazzle_sdk_VectorIndex_n*`) became thin shims
  on top of those helpers.
- `<jni.h>` and every `JNIEnv* / Java_*` entry point are wrapped in
  `#ifdef __ANDROID__` so the iOS xcframework no longer depends on a
  build-host `JAVA_HOME` accidentally leaking jni.h into the include
  path.
- New header `core/platform/dazzle_vs.h` re-exported through the iOS
  xcframework's `DazzleC` module, giving Swift the same surface as
  the Kotlin JNI wrappers.

## [1.0.0-beta.1] — 2026-04-23

First public beta of the Dazzle SDK. Ships three complete layers plus a
cross-platform API contract document.

### Added

#### Layer 1 — embedded Valkey + primitives

- Single `.so` / `xcframework` deployment per platform — `libdazzle.so`
  (Android) and `Dazzle.xcframework` (iOS) statically link every shipped
  Valkey module (valkey-search, TFI) and load them via the patched
  `--loadmodule @static:<name>` loader.
- Typed primitives with parity between Kotlin and Swift:
  `StringKey`, `HashKey`, `ListKey`, `SortedSetKey`, `StreamKey`,
  `SetKey`, `BitmapKey`, `GeoKey`, `HyperLogLogKey`, `LuaScript`,
  `VectorIndex` (FLAT + HNSW), `TfiIndex`.
- `DazzleConfig.execution: ExecutionPolicy` — typed threading knobs:
  dispatcher / executor (native), parallel-read worker count, Valkey
  IO threads, per-command timeout. Presets `.lean`, `.balanced`
  (default), `.parallel`, `.mainThread()`.
- `DazzleModule` with a `@static:<name>` sentinel so bundled modules
  resolve without shipping per-module `.so` files.

#### Layer 2 — Context API

- `ContextStore<T>` — generic, domain-agnostic record store. Dev
  supplies `encode` / `decode`; optional indices (`semanticSearch`,
  `timeRange`, `tags`) activate the corresponding query methods.
  Default implementation composes `HashKey` + `SortedSetKey` + `SetKey`
  + `VectorIndex` under a `cs:<name>:…` namespace.
- `Tool<Args, Ret>` + `ErasedTool` + `JsonSchema` + `jsonSchemaObject {}`
  DSL — serializes to the OpenAI / Anthropic / Gemini
  function-calling wire format via `toDeclaration()`.
- `Message` + `Role` + `ToolCall` + `Completion` + `Delta` — mirror
  the industry chat-completion shape line-by-line.
- `LLMClient` interface (`complete` + `stream`) — dev plugs in their
  inference runtime. `FakeLLMClient` ships for unit tests.
- `Agent` protocol + `ChatAgentImpl` — observable orchestrator backed
  by Kotlin `StateFlow` / Swift `@Observable`. Runs the full tool-call
  loop, streams tokens to a `StreamingMessage`, commits turns to the
  memory store.
- `ContextWindow` (LastN / VectorRecall / All) and `CompactionPolicy`
  (None / TimeRetention / MaxTurns / RollingSummary / Custom) — two
  independent knobs for "what goes into THIS call" vs "what STAYS in
  storage long-term".
- `ContextStore.asSemanticSearchTool(…)` helper for Android — wrap any
  store as a RAG retrieval `Tool`.
- Expanded `DazzleException` / `DazzleError` with
  `ContextOverflow`, `ToolCallParseError`, `ModelLoadFailed`,
  `ToolInvocationTimeout`, `UnknownTool`.

#### Layer 3 — DazzleEdge bundle

- `ModelManifest` (shared JSON + per-platform Kotlin/Swift projections)
  listing Gemma 4 E2B, Llama 3.2 3B, Qwen 2.5 1.5B with pinned URLs +
  sha256 placeholders.
- `ModelDownloader` with resume (`Range: bytes=N-`), SHA-256
  verification, atomic publish, progress callback. Caches under
  `cacheDir/dazzle-edge/<id>/<version>/<filename>`.
- `DazzleEdge.chatAgent(llm:, threadId:, configure:)` — the one-liner
  factory. Boots Valkey with sensible defaults, wires a
  `ContextStore<ChatTurn>` memory under `agent:<threadId>:memory`,
  defaults to `ContextWindow.LastN(20)` + `CompactionPolicy.MaxTurns(200)`.
- `DazzleEdge.ensureModel(…)` + `.isModelReady(…)` — download-on-first-
  use with progress.
- `LiteRtLmClient` — default `LLMClient` impl running Gemma / Llama /
  Qwen on-device via LiteRT-LM. Android ships as `compileOnly` (opt-in
  via consumer `implementation` dep); iOS ships as a separate
  `DazzleLiteRTLM` SPM product.

#### Documentation

- `docs/sdk/API_CONTRACT.md` — single source of truth for the SDK
  surface both platforms project from.
- `docs/architecture/edge_bundle.md` — Layer 3 design spec with the
  known-model manifest format, LiteRT-LM adapter internals, shared
  server lifecycle and migration path from Layer 2.
- `docs/sdk/edge_models.json` — the canonical model manifest.

### Test coverage

Device: **Moto G35 5G (Android 14) + iPhone 17 Pro Simulator (iOS 18).**

- Android instrumented: **73 tests** — 52 primitives, 10 ContextStore,
  3 ChatAgent, 4 DazzleEdge, 2 + 2 LiteRtLmClient (auto-skip when
  Gemma model file not pushed to the device).
- iOS XCTest (Dazzle-Package scheme): **67 tests** — 49 primitives,
  10 ContextStore, 3 ChatAgent, 4 DazzleEdge, 1 LiteRtLmClient marker.

### Known gaps (tracked in [docs/ROADMAP.md](docs/ROADMAP.md))

- **VectorIndex quantized algorithms** (`HNSW_SQ8`, `HNSW_SQ8_RERANK`,
  `HNSW_F16`) + JNI fast paths (`addDirect`, `searchDirect`,
  `nOpenHandle`) ship on Android only. iOS paridad needs a C entry-
  point layer exposed from `libvalkey-server.a`. Optimization
  (footprint + latency), not semantics — FLAT + HNSW cover all
  public-facing queries on both platforms.
- **Tool-call parsing in `LiteRtLmClient`** — the adapters stream
  text deltas correctly but do NOT parse tool_calls out of the
  model's output. Gemma / Llama / Qwen each emit a different syntax;
  per-model parsers land in a follow-up. `Tool<Args, Ret>` + `Agent`
  work today with consumer-provided adapters (cloud API, custom
  fine-tune with a known schema).
- **SHA-256 pinning** — manifest entries carry a placeholder string
  pending a signed release pipeline that computes + pins the real
  hash. The downloader accepts placeholders for dev builds and
  refuses mismatches once real hashes are in place.

### Breaking changes

N/A — this is the first tagged release.
