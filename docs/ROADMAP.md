# Dazzle SDK roadmap

This document describes what the Dazzle SDK ships today, what is planned
for future releases, and what is explicitly out of scope.

iOS and Android mirror each other intentionally: everything listed here
applies to both platforms unless a bullet says otherwise.

---

## 🚀 Post v1.0.0-beta.5 priorities (closing gaps toward GA)

The full beta surface + every gap is listed in
[CHANGELOG.md](../CHANGELOG.md). Short list of what must close before
a non-beta v1.0.0 tag:

### 0. Unify the HTTP-based LLM clients into one C/C++ core (Plan 05)

Today `OpenAICompatibleClient` and `AnthropicClient` ship as four
language implementations each (Kotlin / Swift / Dart / TypeScript)
even though the work is HTTPS + line-buffered SSE + JSON parse.
For `AnthropicClient` we already split the real work into Kotlin +
Swift only and made Flutter / RN thin bridges — but every new
HTTP provider (Cohere, Gemini, OpenRouter, …) still pays a
multi-language tax.

[`docs/plans/05-http-clients-to-jsi-cpp.md`](plans/05-http-clients-to-jsi-cpp.md)
captures the design: collapse all HTTP-based LLM clients into one
C/C++ core inside `libdazzle.so` + JSI on RN + `dart:ffi` on
Flutter. Trigger is "the next HTTP provider lands" — that release
pays the C++ core cost once and amortises it across two providers
immediately.

### 0b. Anthropic-side follow-ups

These didn't block the live verification but are open for the
release after `1.0.0-beta.5`:

- **Tool calling end-to-end against `api.anthropic.com`** —
  the live verification matrix exercised tool calling via
  `chat-kb-rn × HF Llama 3.3 70B`; the Anthropic smokes were
  `chat-memory` (no tools). A `chat-kb` style smoke against
  Anthropic with `search_kb` would close that loop. The bridge +
  parser already handle `tool_use` content blocks +
  `input_json_delta` chunks (verified statically against the
  spec); the missing piece is just running the wired sample with
  Anthropic + a tool-rich query.
- **JVM mock unit tests for `AnthropicClient.kt`** — first
  attempt blocked by the Android library Gradle classpath not
  resolving `com.sun.net.httpserver.*` for `compileReleaseUnitTestKotlin`.
  Fix is a separate JVM-only Gradle module that depends on the
  HTTP-shape parser (probably extracted out of the Android
  library).
- **iOS Keychain / Android Keystore** for API keys — today
  consumers pass the key through `--dart-define` / system
  property / NativeModule env. Production apps should store
  Anthropic / OpenAI keys in the platform secure storage; the
  SDK can offer a simple `KeyProvider` strategy in v1.1.

### 1. SHA-256 pinning in the model manifest

Placeholders still live in `docs/sdk/edge_models.json` and the two
`ModelManifest.{kt,swift}` projections. The re-pinning utility lives
with the paper-companion repo — a maintainer downloads the three
models once, runs the pinning script, and commits the resulting diff
(the script supports `--dry-run` for pre-flight digests
without modifying any file for pre-flight review.

### 2. Documentation polish

- Expand `docs/sdk/README.md` with a 2-page "why this SDK" for an
  external dev coming from OpenAI / LangChain / Firebase Genkit.
- Publish Layer 2 / 3 HTML docs via Dokka + DocC; link from the SDK
  README.

## ⏳ v1.1.0 — multi-agent (Layer 4)

### 3. `Channel<T>` pub/sub — multi-agent communication

Typed pub/sub over Valkey's `PUBLISH` / `SUBSCRIBE` so multiple
`Agent` instances can coordinate inside a single process:

```kotlin
val coord = dazzle.channel<AgentTask>("agents:tasks") {
    encode { t -> """{"id":"${t.id}","action":"${t.action}"}""" }
    decode { json -> parseTask(json) }
}
agentA.tools += coord.asTool(name = "dispatch")
agentB.listen(coord) { task -> handle(task) }
```

**Prerequisites**: wrap the primitives (`Dazzle.publish` already
exists; iOS needs the equivalent `subscribe(channel:) -> AsyncStream`).
Add `Channel.asTool(name:)` + broadcast / P2P modes.

Estimated: **2-3 days** including paired integration tests driven
by `FakeLLMClient` pairs.

## ⏳ v1.2.0 — multimodal + streaming beyond text

- **Image / audio inputs** in `Message.content` — sealed hierarchy
  (`Text`, `Image(bytes, mimeType)`, `Audio(bytes, sampleRate)`).
  Matches Gemini / GPT-4V / Claude 3.
- **Streaming backpressure** — bounded buffer + drop strategy knobs
  on the `Flow<Delta>` / `AsyncStream<Delta>` surfaces so a slow UI
  consumer doesn't build backlog.
- **Apple Foundation Models — richer Tool mapping**. The current
  `FoundationModelsClient` embeds tool declarations in the
  instructions prompt + parses emitted text with `ToolCallParser`.
  A follow-up should generate concrete `FoundationModels.Tool`
  types from `ToolDeclaration` so Apple's native tool-use loop
  handles invocations directly.

## 📝 Later — research-driven

- **Plan 18 follow-through**: close the FP=11 velocity-signal false
  positive in `dazzle-vector` (Android benchmark only).
- **Offline-first resume**: `ModelDownloader` assumes the process is
  alive during the full download. Persist state to `Preferences` so
  a killed app picks up where it left off.

---

## ❌ Out of scope (won't ship)

- **Lua coroutine scheduling API** — Valkey Lua is already atomic;
  no caller-visible benefit to async wrapping.
- **Cluster mode / sharding** — Dazzle is embedded, not distributed.
  Consumers who need a distributed store run standalone Valkey.
- **Direct memory-mapped vector index access** — hnswlib's layout
  makes this a maintenance burden for marginal benefit over
  `searchDirect`.

---

## 📂 Historical — pre-beta transport phase work

The section below is the phase log from before the v1.0.0-beta.1 SDK
surface landed. Kept for context about how Layer 1 reached its current
throughput numbers.

---

## ✅ v1 — current release (commits 2d20c6e..d0e39ac)

**Lifecycle & configuration**

- `DazzleConfig` — typed, immutable configuration for every knob
- `DazzlePersistence { None, Aof, Rdb }` — mutually exclusive sealed state
- `WipeTarget { AOF, RDB, LOGS }` — composable cleanup set
- `DazzleModule { Lua, VectorSearch, TimeSeries, Json, Bloom, Custom }` —
  first-class module enum (only Lua is compiled into arm64 today)
- `DazzleException` — typed sealed error hierarchy
- `DazzleLogger` — injectable logging interface (default: android.util.Log / os_log)
- `DazzleMetrics` — injectable per-command metrics hook (default: no-op)
- Port probing with configurable `portRange` + fallback + strict mode
- Transport modes: `tcpEnabled = true/false` — library always uses
  directCommand internally; TCP listener is only for external clients
- Backward-compat shims for pre-v1 callers (`@Deprecated`)

**Type-safe primitives (9 core data types)**

- `StringKey` — SET/GET/INCR/DECR/APPEND/STRLEN + NX/XX/EX/PX options
- `ListKey` — R/LPUSH/POP, LRANGE, LLEN, LTRIM, LINDEX, LSET, LREM
- `HashKey` — HSET/HGET/HGETALL/HDEL/HEXISTS/HLEN + HINCRBY/HINCRBYFLOAT
  **+ Valkey 8 HFE**: HEXPIRE/HPEXPIRE/HEXPIREAT/HTTL/HPTTL/HPERSIST
- `SetKey` — SADD/SREM/SISMEMBER/SMEMBERS/SCARD/SPOP + SSCAN
- `SortedSetKey` — ZADD/ZSCORE/ZRANK/ZRANGE/ZRANGEBYSCORE/ZREM/ZCARD/ZINCRBY + ZSCAN
- `StreamKey` — XADD (with MAXLEN + strategy)/XLEN/XRANGE/XREVRANGE/XTRIM/XDEL
- `BitmapKey` — SETBIT/GETBIT/BITCOUNT/BITPOS
- `GeoKey` — GEOADD/GEOPOS/GEODIST/GEOSEARCH (BYRADIUS + FROMMEMBER)
- `HyperLogLogKey` — PFADD/PFCOUNT/PFMERGE

**Facade & operations**

- `Dazzle` facade — factory methods for all 9 primitives + `namespace(prefix)`
- Key meta ops: EXISTS/DEL/TYPE/EXPIRE/PEXPIRE/EXPIREAT/PERSIST/TTL/PTTL
- Server ops: DBSIZE/FLUSHDB/FLUSHALL/PING
- Transactions: `transaction { }` DSL + WATCH/UNWATCH
- Pub/Sub: PUBLISH (SUBSCRIBE listener = v1.2)
- Scripting: `script(src).eval(keys, args)` with auto SHA caching
- Scan iteration: `scan(match, count)` + HSCAN/SSCAN/ZSCAN per primitive
- Server diagnostics: `server().info()` (typed ServerInfo), `memoryUsage(key)`,
  `slowLog(count)`, `bgSave()`, `lastSaveTime()`, `time()`

**Native layer**

- RESP-2 parser (Kotlin RespParser + Swift RespParser) — decodes the raw
  directCommand reply into a typed RespValue tree
- Valkey 8 fake-client compatibility fix — `CLIENT_ID_CACHED_RESPONSE` +
  stub `conn` + pre-populated `peerid`/`sockname` so the in-process
  dispatch path works correctly with Valkey 8's prepareClientToWrite guard

---

## ✅ v1.1 — shipped 2026-04-18 (`a54eed6..92972bd`, squash merges #2/#4/#5 + post-merge benches)

**Plan 02 Stage 1 — Parallel read workers**

- `core/transport/dazzle_worker_pool.c` — MPSC ring + eventfd + per-slot
  striped rwlocks (64 stripes)
- Direct app→worker path that bypasses the AE event loop for reads
- Fake-client `pending_write = 1` preset (fixes Blocker D — the K≥4
  concurrent-caller deadlock on `putClientInPendingWriteQueue`)
- Hot-command lookup cache, stack-allocated argv, inline lean client reset
- SoC-aware default worker count (2 on small-cores-only SoCs, 4 otherwise)
- Benchmark: +10.9 % aggregate ops/s, p99 −4 %, and 23 k pure-retrieval
  ops/s with `dazzle-incremental` at p99 <1 ms

**Plan 06 — Suspend-native SDK**

- `DazzleServer.directCommandSuspend` + typed primitive suspend variants
  (Kotlin) and `async throws` mirrors (Swift)
- Unblocks concurrent-coroutine workloads that previously deadlocked the
  Dispatchers.Default pool

**Plan 07 — Incremental backend**

- `DazzleIncrementalIoTManager` — delta-updated rolling window on
  ingest instead of the `@Synchronized`-guarded ArrayDeque of
  `dazzle-precompute`
- Benchmark: new Pareto frontier — retrieval = 2 177 µs (matches
  precompute v1), ingest = 549 µs (9.4× faster than precompute v1 at N=5 000)

**Plan 07 follow-up — Precompute v2 (materialised-string)**

- `DazzlePrecomputeIoTManager` rewritten: rolling window, OLS trend,
  window anomalies and the full ASCII context block are assembled inside
  a single Lua EVALSHA. Kotlin mirrors the returned block into the
  snapshot cache via one direct-path `HSET ctx_block`
- `@Synchronized` monitor and Kotlin `ArrayDeque` removed — precompute
  is now lock-free from the Kotlin side, so the Phase 4 worker pool
  delivers parallel gains here too
- Benchmark (Moto g35, K=8 parallel, 80/20): **1 344 → 12 062 ops/s
  (+798 %)**, retrieval p50 **668 → 106 µs**, p99 **54.4 → 4.3 ms**.
  Parallel now beats MainThread (+35 % at K=8). Report:
  `(internal benchmark report; released with paper)`

**Phase 5 B — JNI class-ref cache + single-field HGET**

- `JNI_OnLoad` caches `java/lang/String` and `String[]` class references
  as global refs; per-call `FindClass` removed from
  `nativeDirectReadFields`, `nativeDirectPipeline`, `nativeSnapshotMHmget`,
  and the new single-field path
- New `nativeDirectReadField(key, field) → String?` backed by
  `valkey_snapshot_hget_typed(key, field, buf, cap)` — skips the
  `NewObjectArray` + class-lookup overhead for callers that want one
  field. Wired through `HashKey.getDirect(field)` into
  `DazzlePrecomputeIoTManager.buildContextBlock` (the precompute v2
  hot path is exactly one HGET of `ctx_block`)
- `nativeDirectReadFields` now stack-allocs the field-ptr / UTF-8
  buffers up to 64 fields (heap fallback for larger)
- Benchmark (Moto g35, K=8 parallel, 80/20, precompute v2): **12 062 →
  12 519 ops/s (+3.8 %)**, p50 **106 → 89 µs (−15.8 %)**, p99 **4269 → 4055 µs (−5.0 %)**.
  MainThread: 8 946 → 9 424 ops/s (+5.3 %), p99 2 832 → 2 567 µs (−9.4 %)

**Worker-pool global barrier (correctness + perf)**

- `core/transport/dazzle_worker_pool.{c,h}` — added a process-wide
  `pthread_rwlock_t` the worker pool consults on every dispatch:
  workers and whitelisted main-thread commands take rdlock + per-slot
  lock; non-whitelisted commands (EVAL/EVALSHA/DEBUG/… — anything whose
  keyspace footprint cannot be inferred from `argv[1]`) take wrlock and
  exclude every worker for the duration of the call
- `core/transport/dazzle_transport.c` — `directCommandHandler` and
  `ringDrainHandler` updated to pair the barrier acquisition with slot
  locking under a single cleanup path
- Closes a correctness hole: `req->slot` is derived from `argv[1]`
  unconditionally, so for EVAL/EVALSHA that argument is the script
  body/SHA (not a key) and slot locking gave no protection between a
  Lua-script write into e.g. `sensor:stats` and a concurrent worker
  HMGET on the same hash via a different stripe. Surfaced at K=8 as
  `malformed RESP: expected N bytes at pos=M, only K available` on
  `dazzle-incremental` (RESP reply truncation during a racing HSET)
- Benchmark (Moto g35, K=8, 80/20):
  - `dazzle-incremental` — previously crashed → **4 972 ops/s MT /
    9 684 ops/s PAR, zero errors** (p50 1.30 / 0.67 ms, p99 8.07 / 2.70 ms)
  - `dazzle-precompute v2` (unexpected compounding gain — the barrier
    also closed a subtle EVAL-vs-worker race that was silently
    degrading throughput): **12 519 → 34 356 ops/s PAR (+174 %)**,
    p50 **89 → 44 µs**, p99 **4 055 → 1 370 µs**; MainThread
    **9 424 → 16 657 ops/s (+77 %)**, p99 2 567 → 2 092 µs.
    Confirmed with a repeat run at 34 701 ops/s (within 1 %)
- Report: `(internal benchmark report; released with paper)`

---

## ⏳ v1.2 — planned (quality-of-life)

- Pub/Sub subscribe listener as Kotlin Flow / Swift AsyncStream
- Deferred command recording for true MULTI/EXEC atomicity
- Connection pooling for the TCP path
- iOS mirror for ServerInfo / DazzleMetrics
- Serialization helpers (Kotlin data class → Hash mapping)
- iOS mirror for Plan 07 follow-up (Precompute v2 — Android shipped in
  v1.1; `DazzlePrecomputeIoTManager.swift` still on v1 Kotlin-array
  pattern)

---

## ⏳ v2 — planned (Valkey 8 modules)

Shipping additional Valkey 8 modules for arm64:

- `valkey-search` — FT.CREATE / FT.SEARCH / HSET VECTOR / KNN queries
- `valkey-ts` — native TS.ADD / TS.RANGE / compaction rules
- `valkey-json` — JSON.SET / JSON.GET / JSONPath
- `valkey-bloom` — BF.* / CF.* / TDIGEST.* / TOP-K

---

## ❌ Out of scope

- Cluster commands (CLUSTER *)
- Replication (REPLICAOF / SYNC / FAILOVER)
- ACL subsystem
- CONFIG SET runtime overrides
