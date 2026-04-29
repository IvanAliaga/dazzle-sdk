# Companion Engineering Report — Dazzle paper v2

**Ivan Aliaga** — *Universidad Ricardo Palma, Lima, Peru* — *April 2026*

This report keeps three sections of detailed engineering material
that the main paper (`paper_v2_en.md`) used to inline. Moving them
out of the paper trims it from ~21 to ~17 pages — a more
appropriate length for a tier-1 venue — without dropping the
underlying contributions, which are still cited and summarised in
the paper but no longer reproduced verbatim.

The three sections are:

1. **§1 — Performance evolution of the Dazzle stack.**
   Cumulative effect of five in-process transport redesigns on
   concurrent retrieval throughput (paper §5.7, Table 10).
2. **§2 — SQLite-family vector N-sweep.**
   `default` / `optimized` / `precompute` variants for `sqlite-vec`
   and SQLiteAI on Moto G35 5G across N ∈ {200, 1k, 5k, 10k, 20k}
   (paper §5.8.4, Tables 12 / 13 / 14).
3. **§3 — Flutter `EventChannel` bridge — three invariants and
   live-verification matrix.** The detailed engineering trace of
   the multi-turn empty-assistant bug family in the SDK plugin,
   plus the 4-stack live-verification matrix against
   `api.anthropic.com` (paper Appendix A.2 + A.3, the high-level
   summary stays in the paper).

Citations between this report and the paper are bidirectional: the
paper points here where it summarises a section it used to inline,
and this report assumes the reader has the paper open for context.

---

## 1. Performance evolution of the Dazzle stack

The retrieval latency of the current stack is the cumulative result
of several in-process transport redesigns. Table 1 below reports
the cumulative effect on the highest-impact metric of the paper:
concurrent retrieval throughput at K = 8, Moto G35 5G, 80/20 mix.

**Table 1 — Retrieval throughput progression** (ops/s, K = 8,
Moto G35 5G, 80/20 read/write mix).

| Stack version                       | incremental ops/s | precompute ops/s |
|-------------------------------------|------------------:|-----------------:|
| Baseline (pre-snapshot-cache)       | 9 684             | 34 356           |
| + bucketed snapshot index           | 9 604             | 33 994           |
| + post-EVAL auto-mirror             | 27 976            | 33 011           |
| + inline HSET ctx_block             | **28 057**        | **38 156**       |

The biggest needle-mover is the **post-EVAL auto-mirror (+189 % on
incremental)**: exposing Lua's internal writes to the snapshot cache
without the backend having to perform manual ceremony in
Kotlin/Swift. The inline-HSET change (~14 % additional on
precompute) eliminates one extra FFI/JNI crossing per ingest by
moving the explicit HSET inside the Lua script.

Each optimization was verified as an independent contribution; the
final stack has lived in `main` since April 2026.

---

## 2. SQLite-family vector N-sweep

To close the "single SQLite path" gap, we ran a focused benchmark on
Moto G35 5G over SQLite-family vector backends only, with
dim = 384, k = 10, 100 queries, and 3 rounds. Because this is an
independent rerun (different run timestamp and thermal state) from
the cross-backend grid in paper §5.8.2 / Table 11, constant-factor
drift is expected and can be substantial under mobile thermal
scaling.

The N = 20 000 operating-point rows for sqlite variants are merged
into Table 11 of the main paper so all engines are compared in one
place; the per-N detail lives in Tables 2 / 3 / 4 below.

**Table 2 — N-sweep retrieval p50 across SQLite-family vector
variants** (µs, mean ± SD across 3 rounds, Moto G35 5G).

| Variant                       | N = 200            | N = 1 k            | N = 5 k            | N = 10 k           | N = 20 k          |
|-------------------------------|-------------------:|-------------------:|-------------------:|-------------------:|------------------:|
| sqlite\_plain                 | 598 540 ± 272 190  | 597 698 ± 269 692  | 597 950 ± 274 711  | 596 814 ± 272 490  | 744 669 ± 19 829  |
| sqlite\_vec\_default          | 916 ± 32           | 1 446 ± 15         | 7 271 ± 435        | 14 152 ± 1 293     | 27 850 ± 1 380    |
| sqlite\_vec\_optimized        | 860 ± 39           | 1 435 ± 12         | 7 145 ± 392        | 14 163 ± 908       | 28 575 ± 1 193    |
| sqlite\_vec\_precompute       | 817 ± 5            | 1 431 ± 20         | 7 421 ± 348        | 14 590 ± 473       | 26 505 ± 201      |
| sqlite\_vector\_ai\_default   | 135 ± 1            | 303 ± 3            | 1 475 ± 19         | 6 436 ± 84         | 9 812 ± 363       |
| sqlite\_vector\_ai\_optimized | 135 ± 3            | 302 ± 6            | 1 592 ± 217        | 6 448 ± 47         | 9 570 ± 548       |
| sqlite\_vector\_ai\_precompute| 111 ± 2            | 233 ± 4            | 889 ± 18           | 1 593 ± 1          | 3 072 ± 4         |

**Table 3 — N-sweep ingest total across SQLite-family vector
variants** (ms, mean ± SD).

| Variant                       | N = 200          | N = 1 k         | N = 5 k         | N = 10 k        | N = 20 k         |
|-------------------------------|-----------------:|----------------:|----------------:|----------------:|-----------------:|
| sqlite\_plain                 | 151.13 ± 10.95   | 100.60 ± 3.66   | 466.02 ± 19.14  | 935.31 ± 17.16  | 1 798.88 ± 37.88 |
| sqlite\_vec\_default          | 23.62 ± 1.94     | 62.19 ± 5.08    | 346.89 ± 6.32   | 685.57 ± 17.79  | 1 316.07 ± 19.23 |
| sqlite\_vec\_optimized        | 9.66 ± 2.05      | 47.18 ± 2.65    | 242.90 ± 34.39  | 477.08 ± 70.52  | 869.24 ± 43.73   |
| sqlite\_vec\_precompute       | 9.35 ± 0.32      | 42.14 ± 7.70    | 284.08 ± 12.66  | 488.35 ± 72.88  | 870.46 ± 46.64   |
| sqlite\_vector\_ai\_default   | 6.08 ± 0.84      | 22.67 ± 5.38    | 190.62 ± 13.44  | 354.39 ± 24.14  | 723.31 ± 14.55   |
| sqlite\_vector\_ai\_optimized | 5.98 ± 1.44      | 24.83 ± 5.15    | 189.51 ± 19.67  | 353.42 ± 20.85  | 685.26 ± 6.30    |
| sqlite\_vector\_ai\_precompute| 5.17 ± 0.13      | 25.42 ± 4.21    | 180.98 ± 10.03  | 352.86 ± 14.39  | 707.92 ± 29.17   |

**Table 4 — N-sweep storage footprint across SQLite-family vector
variants** (DB size after ingest, MB).

| Variant                       | N = 200 | N = 1 k | N = 5 k | N = 10 k | N = 20 k |
|-------------------------------|--------:|--------:|--------:|---------:|---------:|
| sqlite\_plain                 | —       | —       | —       | —        | —        |
| sqlite\_vec\_default          | 0.004   | 0.004   | 7.770   | 15.508   | 31.004   |
| sqlite\_vec\_optimized        | 0.004   | 0.004   | 7.770   | 15.508   | 31.004   |
| sqlite\_vec\_precompute       | 0.004   | 0.004   | 7.770   | 15.508   | 31.004   |
| sqlite\_vector\_ai\_default   | 0.012   | 0.012   | 9.805   | 19.590   | 46.652   |
| sqlite\_vector\_ai\_optimized | 0.012   | 0.012   | 9.805   | 19.590   | 46.652   |
| sqlite\_vector\_ai\_precompute| 0.012   | 0.012   | 9.805   | 19.590   | 46.652   |

Relative to Dazzle SQ8 at the same operating point (208 µs from
paper Table 11 at N = 20 000), the closest SQLite-family path in
this run (`sqlite_vector_ai_precompute` at 1 407 µs) is ~6.8×
slower. This comparison still spans algorithm classes (HNSW vs
linear scan) and should be read as an envelope reference, not as a
claim of intrinsic engine superiority.

---

## 3. Flutter `EventChannel` bridge — three invariants and live-verification matrix

### 3.1 Three Flutter `EventChannel` bridge invariants

Three production bugs in the Flutter bridge surfaced during
end-to-end verification of `AnthropicClient` on the iOS simulator.
Each bug produced a silently empty assistant turn on the second
round of a multi-turn chat, even though the first turn worked.
We document them here because the same failure family occurs in
*any* `EventChannel`-backed bridge, not just this adapter.

**Invariant 1 — Tasks per subscription, `onCancel` is a no-op.**
The bridge originally held a single `activeTask` member that each
`onListen` reassigned. When Dart closed the subscription for turn N
on receipt of `Delta.end`, Flutter posted an *asynchronous*
`onCancel` to the platform thread. By the time it landed, turn N+1
had already started and reassigned `activeTask`, so the late
`onCancel` cancelled turn N+1's task instead. The HTTP
`URLSessionTask` reported `NSURLErrorCancelled (-999)` and the JSON
response never reached the parser. Fix: every `onListen` mints its
own `subId` and stores its task in a `tasksBySubId` map; the task
auto-deregisters on completion and `onCancel` becomes a no-op.

**Invariant 2 — Never call `events(FlutterEndOfEventStream)` for
per-turn streams.** Calling `FlutterEndOfEventStream` after
`Delta.end` permanently closes the entire `EventChannel` from
Flutter's point of view; subsequent `onListen` callbacks fire but
the corresponding `events(...)` calls are silently dropped. Fix:
signal the end of a single turn with an ordinary
`{"type": "end"}` frame and let the Dart shim close its own
`StreamController`. The `EventChannel` itself stays alive across
turns.

**Invariant 3 — `streamId` cookie filters residual frames.** After
applying Invariants 1 and 2, an intermittent third failure mode
appears: the new subscription for turn N+1 receives, as its first
event, a residual `type: "end"` from turn N's buffer. This is
documented broadcast-stream behaviour in some Flutter backends
and cannot be prevented from the bridge. Fix: the Dart shim mints
a monotonic `streamId` per `stream()` call, passes it in the
`receiveBroadcastStream` args, and drops any incoming frame whose
`streamId` does not match. The native bridge propagates the cookie
on every emitted frame.

The three invariants are applied preventively to every
`EventChannel`-backed bridge in the SDK — `AnthropicBridge.{kt,swift}`,
`LiteRtBridge.kt`, `FoundationModelsBridge.swift` — and the
`AnthropicBridge.kt` Flutter-Android path additionally needs
`FlutterEventSink.success(...)` to be hopped onto the UI thread,
because the sink is `@UiThread`-annotated and crashes when called
from `Dispatchers.IO`.

### 3.2 Live verification matrix — `api.anthropic.com`

End-to-end verification was executed against the real
Anthropic Messages API with `claude-haiku-4-5-20251001` to confirm
that the adapter layer, the three bridge invariants, and the
storage-side primitives compose cleanly in a real network round-trip:

| Stack                            | Sample                | Result |
|----------------------------------|-----------------------|--------|
| React Native, Android (Moto G35 5G) | `chat-kb-rn`        | PASS — 5-turn dialogue (1 user + 2 assistant + 2 tool); the final assistant text cites verbatim numbers from the on-device FAQ corpus (e.g. *"76× faster than sqlite-vec"*, *"A14 Bionic"*), exercising the full HNSW\_SQ8 → `tool_result` → second `POST /v1/messages` → synthesis loop end-to-end. |
| iOS native (simulator, iPhone 17 Pro) | `DazzleChatMemory` | PASS — 4-turn dialogue; multi-turn memory persists through `ContextStore<ChatTurn>`. |
| Flutter, Android (Moto G35 5G)   | `chat-memory-flutter` | PASS — post `AnthropicBridge.kt` UI-thread fix. |
| Flutter, iOS (simulator)         | `chat-memory-flutter` | PASS — post the three `EventChannel` invariants of §3.1. |

The `chat-kb-rn` row has the highest coverage: it exercises the
on-device HNSW\_SQ8 vector index, the NEON-SDOT embedder, the full
`tool_use → tool_result → second turn` loop, and the model's
final synthesis grounded in the retrieved corpus — so a regression
anywhere in the stack (transport, adapter, bridge, storage) shows
up as either a mismatched number in the assistant's reply or a
silent empty turn.

---

## License

This companion report is released under Apache-2.0 (same as the
main paper) and is intended to be cited from
`research/paper/paper_v2_en.md` §5.7, §5.8.4, and Appendix A.
