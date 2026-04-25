# Dazzle SDK — API contract (cross-platform source of truth)

**Scope**: every primitive and Layer-2 API surface the SDK exposes to
consumers. Both the Kotlin (Android) and Swift (iOS) bindings are
projections of this document. New language bindings (Python, Node,
Rust, Linux-C) must implement the same method set with the same names
and semantics.

**When this document and the code disagree, the code on the side the
user is running is authoritative for that platform and one of the two
has a bug.** The intent is: this document = spec, both platforms =
implementations, zero divergence in commit history beyond what's
listed under "Platform-specific exceptions" below.

---

## Layer 1 — Primitives

All primitives are obtained via the `Dazzle` facade (`server.client()`
on iOS, `DazzleServer.client()` on Android). They are cheap value types
that wrap a key name + a server reference; no object pooling needed.

Every method either returns a value or throws a typed exception
(`DazzleException` on Kotlin, `DazzleError` on Swift) — no silent nulls
for real errors. Null is reserved for semantic "key/field absent".

### StringKey

| Method | Return | Semantics |
|---|---|---|
| `set(value, options = SetOptions())` | `Bool` | `SET` with NX/XX/EX/PX via options. Returns `true` on OK, `false` if NX/XX blocked. |
| `get()` | `String?` | `GET`. Null when key absent. |
| `append(value)` | `Int64` | `APPEND`. Returns the new total length. |
| `length()` | `Int64` | `STRLEN`. 0 when absent. |
| `incr()` | `Int64` | `INCR` — atomic +1. Creates key as `0` first if absent. |
| `incrBy(delta)` | `Int64` | `INCRBY`. |
| `incrByFloat(delta)` | `Double` | `INCRBYFLOAT`. |
| `decr()` / `decrBy(delta)` | `Int64` | `DECR` / `DECRBY`. |
| `exists()` | `Bool` | `EXISTS`. |
| `deleteKey()` | `Bool` | `DEL`. `true` if the key existed. |

`SetOptions` carries `onlyIfAbsent` (NX), `onlyIfPresent` (XX),
`ttlSeconds` (EX), `ttlMillis` (PX).

### HashKey

| Method | Return |
|---|---|
| `set(field, value)` | `Bool` |
| `setAll(pairs)` | `Int64` — new fields added |
| `get(field)` | `String?` |
| `getDirect(field)` | `String?` — snapshot-cache fast path, RESP fallback |
| `mGet(fields…)` | `[String?]` |
| `mGetDirect(fields…)` | `[String?]` — snapshot-cache fast path |
| `getAll()` | `[String:String]` |
| `delete(fields…)` | `Int64` — field count removed |
| `delete()` / `deleteKey()` | `Bool` — entire hash dropped |
| `exists(field)` | `Bool` |
| `length()` | `Int64` |
| `keys()` / `values()` | `[String]` |
| `scan(match?, count?)` | iterator of `[String:String]` pages |
| `incrBy(field, delta)` | `Int64` |
| `incrByFloat(field, delta)` | `Double` |
| `expireField(field, seconds)` | status code (1/0/-2) |
| `expireFields(seconds, fields…)` | `[Int]` — one code per field |
| `pExpireField(field, millis)` / `pExpireFields` | same shape, ms precision |
| `expireFieldAt(field, unixSeconds)` | status code |
| `ttlField(field)` / `ttlFields(fields…)` | seconds remaining, `-1` no TTL, `-2` missing |
| `pTtlField(field)` / `pTtlFields` | same, ms |
| `persistField(field)` | `Bool` — TTL cleared |

### ListKey

| Method | Return |
|---|---|
| `rpush(values…)` / `lpush(values…)` | `Int64` — new length |
| `rpop()` / `lpop()` | `String?` — null when empty |
| `range(start, stop)` | `[String]` — negative indices count from tail |
| `length()` | `Int64` |
| `trim(start, stop)` | `Bool` — OK (cannot fail on empty) |
| `index(idx)` | `String?` — null out of range |
| `set(idx, value)` | `Bool` — throws on out-of-range |
| `remove(count, value)` | `Int64` — LREM count semantics (>0 head→tail, <0 tail→head, 0 all) |
| `exists()` / `deleteKey()` | `Bool` |

### SortedSetKey

| Method | Return |
|---|---|
| `add(score, member)` | `Bool` — true if new |
| `addAll(members: [String:Double])` | `Int64` — new members count |
| `score(member)` | `Double?` |
| `rank(member)` / `revRank(member)` | `Int64?` — 0-based, null when absent |
| `range(start, stop)` | `[String]` — by ascending rank |
| `rangeWithScores(start, stop)` | `[ScoredMember]` |
| `rangeByScore(min, max)` | `[String]` |
| `rangeByScoreWithScores(min, max)` | `[ScoredMember]` |
| `cardinality()` | `Int64` |
| `count(min, max)` | `Int64` — members in score window |
| `incrBy(member, delta)` | `Double` — new score |
| `remove(members…)` | `Int64` |
| `removeRangeByScore(min, max)` | `Int64` |
| `exists()` / `deleteKey()` | `Bool` |

### StreamKey

| Method | Return |
|---|---|
| `add(fields, maxLen?, trimStrategy=APPROX, id="*")` | `String?` — assigned id |
| `length()` | `Int64` |
| `range(start="-", end="+", count?)` | `[Entry]` — oldest first |
| `revRange(end="+", start="-", count?)` | `[Entry]` — newest first |
| `trim(maxLen, strategy=APPROX)` | `Int64` — entries evicted |
| `delete(ids…)` | `Int64` — entries removed by id |
| `exists()` / `deleteKey()` | `Bool` |

### SetKey

| Method | Return |
|---|---|
| `add(members…)` | `Int64` — new members count |
| `remove(members…)` | `Int64` — removed count |
| `contains(member)` | `Bool` |
| `members()` | `Set<String>` |
| `cardinality()` | `Int64` |
| `scan(match?, count?)` | iterator of `[String]` pages |
| `deleteKey()` / `exists()` | `Bool` |

### LuaScript

| Method | Return |
|---|---|
| `eval(keys?, args?)` | `RespValue` — caches SHA after first call |
| `evalSha(keys?, args?)` | `RespValue` — raises NOSCRIPT if not cached yet |
| `load()` | `String` — SHA1 hex |

### VectorIndex

| Method | Return |
|---|---|
| `create()` | `Bool` — `false` if already exists |
| `drop()` | `Bool` |
| `add(id, vector, metadata={})` | `Void` — FT.HADD |
| `search(query, k=10, returnFields=[], efRuntime=0)` | `[SearchResult]` |
| `addDirect(id, vector)` | `Void` — fast path, no RESP |
| `addBatchDirect(ids, vectors)` | `Void` — batch fast path |
| `searchDirect(query, k=10, efRuntime=0)` | `[(id, distance)]` — fast path, no RESP |

Algorithms: `FLAT`, `HNSW`, `HNSW_SQ8`, `HNSW_SQ8_RERANK`, `HNSW_F16`
on both platforms. Quantised variants (`HNSW_SQ8` / `HNSW_F16`) require
the `DAZZLE_VECTOR_SIMSIMD` build flag (default on for the shipped
libdazzle.so / Dazzle.xcframework) and only support `Metric.COSINE`.

Metrics: `COSINE`, `L2`, `IP`.

### Dazzle (facade)

| Method | Return |
|---|---|
| `string / list / hash / set / sortedSet / stream / bitmap / geo / hyperLogLog (key)` | typed wrapper |
| `namespace(name)` | new facade with `name:` prefix |
| `vectorIndex(…)` | `VectorIndex` |
| `script(source)` | `LuaScript` |
| `exists(keys…)` / `delete(keys…)` / `type(key)` | key-meta |
| `expire / pExpire / expireAt / persist / ttl / pTtl (key, …)` | TTL family |
| `dbSize / flushDb / flushAll / ping` | server meta |

---

## Layer 2 — Context API

### ContextStore<T>

Generic typed record store. Dev supplies `encode/decode`; optional
indices (`semanticSearch`, `timeRange`, `tags`) activate specific query
methods.

| Method | Return |
|---|---|
| `put(id, value)` / `putAll(entries)` | `Void` |
| `get(id)` / `getAll(ids)` | `T?` / `[T?]` |
| `delete(id)` | `Bool` |
| `count()` | `Int64` |
| `flush()` | `Void` |
| `iterate(match?)` | iterator of `(String, T)` |
| `semanticSearch(query, k=10)` / `semanticSearch(vector, k=10)` | `[Hit<T>]` — empty if no embedder |
| `byTimeRange(start, end, limit=1000)` | `[(String, T)]` — empty if no timeExtractor |
| `byTag(tag)` / `byTags(allOf)` | iterator of `(String, T)` — empty if no tagsExtractor |
| `close()` | `Void` |

Reserved hash field name: `_embedding` (throws if the encoder returns it).

### Tool<Args, Ret>

| Member | Shape |
|---|---|
| `name: String` | `domain.verb` convention |
| `description: String` | what the LLM reads to pick |
| `argsSchema: JsonSchema` | parameters shape |
| `invoke(args, ctx) async throws -> Ret` | implementation |
| `argsFromJson(raw) throws -> Args` | decoder |
| `returnToJson(value) -> String` | encoder |
| `toDeclaration() -> ToolDeclaration` | OpenAI-compatible serialization |

`ToolContext`: `{ execution, stores, publish? }`.
`JsonSchema`: sealed hierarchy `object` / `primitive` / `array`.

### Message, Role, ToolCall, Completion, Delta

Match the OpenAI / Anthropic / Gemini wire format exactly so prompts
port line-by-line:

```kotlin
data class Message(role: Role, content: String, toolCalls: List<ToolCall> = [], toolCallId: String? = null)
enum Role { system, user, assistant, tool }
data class ToolCall(id: String, name: String, arguments: String /* raw JSON */)

sealed class Completion { Text(Message); ToolCalls(Message) }
sealed class Delta { Text(chunk); ToolCallStart(id,name); ToolCallArgs(id,chunk); End }
```

### LLMClient

| Method | Return |
|---|---|
| `modelId: String` | descriptive |
| `complete(messages, tools=[])` | `Completion` |
| `stream(messages, tools=[])` | stream of `Delta` |
| `close()` | `Void` |

### LLMClient adapters (ship with the SDK)

Four adapters bundle with Dazzle and cover the common runtime
surface. Consumers implement their own `LLMClient` when the list
below doesn't fit.

| Adapter | Platform | Runtime | Notes |
|---|---|---|---|
| `LiteRtLmClient` | Android + iOS | Google LiteRT-LM (`.litertlm`) | Opt-in (`DazzleLiteRTLM` SPM product / Android `compileOnly`); tool-call parser baked in |
| `LlamaCppClient` | Android + iOS | **Embedded** llama.cpp (GGUF) | Ships inside `libdazzle.so` / `Dazzle.xcframework`; pinned tag `b4120`; local patches under `versions/llama_cpp/patches/` |
| `OpenAICompatibleClient` | Android + iOS | Remote `/v1/chat/completions` | Covers OpenAI, HuggingFace Inference Providers, Ollama local, vLLM, LM Studio, Groq, Together AI, any proxy speaking the same wire format |
| `FoundationModelsClient` | iOS 26+ / macOS 26+ | Apple Intelligence (3 B on-device) | Free at runtime; gated on `SystemLanguageModel.default.availability == .available` |

All four emit the same `Delta.ToolCallStart` / `Delta.ToolCallArgs`
shape so a consumer can swap adapters without touching the Agent
or Tool loop.

### Agent

Observable orchestrator. Implementations are platform-native
(`StateFlow` on Kotlin, `@Observable` on Swift).

| Member | Shape |
|---|---|
| `threadId: String` | stable identifier for resumption |
| `messages: Observable<[ChatTurn]>` | committed history |
| `streaming: Observable<StreamingMessage?>` | in-flight token stream |
| `status: Observable<AgentStatus>` | idle / thinking / toolCalling / streaming / error |
| `tools: List<ErasedTool>` / `[any ErasedTool]` | mutable set |
| `send(input: String)` | fire-and-forget user turn |
| `cancel()` | abort in-flight turn |
| `compact() async` | run the CompactionPolicy now |
| `close()` | release all resources |

### ExecutionPolicy

```
{
  dispatcher / executor: native (CoroutineDispatcher | TaskExecutor),
  readWorkers: Int (0 = off, -1 = auto, N = fixed),
  ioThreads: Int (0 = off),
  commandTimeout: Duration,
}
```

Presets: `lean`, `balanced` (default), `parallel`, `mainThread()`.

### ContextWindow

Sealed hierarchy — picks WHAT goes into the next LLM call:
- `LastN(n)`
- `All`
- `VectorRecall(keepRecent, k, store, embedder)`

### CompactionPolicy

Sealed hierarchy — picks WHAT STAYS IN STORAGE:
- `None`
- `TimeRetention(retention: Duration)`
- `MaxTurns(maxTurns)`
- `RollingSummary(everyNTurns, keepRecent, summarizer)`
- `Custom(fn)`

---

## Platform-specific exceptions (documented, not invisible)

These are the points where the two platforms intentionally diverge.
Anything outside this list should be treated as a bug, not a feature.

| Area | Android (Kotlin) | iOS (Swift) | Reason |
|---|---|---|---|
| Dispatcher field | `CoroutineDispatcher` | `TaskExecutor` (iOS 18+; closure-based fallback on iOS 17) | Native concurrency model differs |
| VectorIndex quantized variants | full set on both platforms (FLAT, HNSW, HNSW_SQ8, HNSW_SQ8_RERANK, HNSW_F16) with `addDirect` / `addBatchDirect` / `searchDirect` fast paths | same | — |
| Observable surface | `StateFlow<T>` | `@Observable` property with `@Bindable` | Each platform's idiomatic reactive primitive |
| Template engine | minimal home-grown `{placeholder}` replacer | same | intentional no-op |
| `exists()` on HashKey | has a no-arg `exists()` AND a field-level `exists(field)` | field-level only; ContextStore uses `getAll().isEmpty` to probe | historical accident; iOS would gain a no-arg `exists()` in a follow-up |

---

## Test expectations

Both platforms run an instrumented test suite against the same
behaviour. Target: **≥60 tests per platform, functionally equivalent
pairs**. Divergences beyond ±5 tests must be justified against this
contract.

Current status (April 2026):

| Platform | Primitives | ContextStore | Agent | Total |
|---|---|---|---|---|
| Android (Moto G35 5G) | 52 | 10 | 3 | **65** |
| iOS Simulator (iPhone 17 Pro) | 49 (no SQ8/F16) | 10 | 3 | **62** |

The 3-test delta is accounted for by VectorIndex quantized algorithms
listed in the platform exceptions above.

---

## How to add a new primitive

1. Add method to the Kotlin primitive in `sdk/android/src/main/java/dev/dazzle/sdk/…`.
2. Add parallel method to Swift in `sdk/ios/Sources/DazzlePrimitives.swift`.
3. Update the table in this document.
4. Add matching tests to both platforms' instrumented suites.
5. Build must stay green on both devices; no commit merges without
   parity.

## How to add a new Layer-2 concept

1. Design in this document first (shape, types, semantics).
2. Implement on both platforms in the same commit.
3. Tests on both platforms in the same commit.
4. Only then expose in public API.
