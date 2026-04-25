# Dazzle — architecture

Dazzle embeds a patched Valkey server in a mobile process and
replaces its network I/O with an in-process pipeline. This document
sketches the layers that matter when reading the code.

## High-level layout

```
┌──────────────────────────────────────────────────────────────────┐
│  App (Kotlin / Swift)                                            │
│    uses DazzleServer + typed Key APIs                            │
└────────────────────────────────┬─────────────────────────────────┘
                                 │
┌────────────────────────────────▼─────────────────────────────────┐
│  sdk/android/  |  sdk/ios/          language bindings            │
│  - DazzleServer, DazzleConfig, Key wrappers                      │
│  - JNI (Android) / C shim + module.map (iOS)                     │
└────────────────────────────────┬─────────────────────────────────┘
                                 │
┌────────────────────────────────▼─────────────────────────────────┐
│  core/                          project IP                       │
│  - transport/dazzle_transport.c    dispatch: pipe → ring → io_uring │
│  - transport/ring_buffer.h      Phase 2 SPSC                     │
│  - transport/io_uring_transport.h  Phase 3 batch syscall         │
│  - cache/snapshot.h             Phase 1+5 direct reads           │
│  - platform/dazzle_ios.c/h      iOS bridge                       │
│  - compat/dazzle_compat.h       v8 / v9 / v10+ shims             │
└────────────────────────────────┬─────────────────────────────────┘
                                 │
┌────────────────────────────────▼─────────────────────────────────┐
│  Valkey upstream (fetched at build time, patched)                │
│  - Android: FetchContent(GIT_TAG …) in sdk/android/src/main/cpp  │
│  - iOS:     git clone --branch $VALKEY_VERSION in sdk/ios/build.sh│
│  - patches: versions/<version>/patches/*.patch                   │
└──────────────────────────────────────────────────────────────────┘
```

## Transport layer — phases

The write path has grown in phases; the read path is separate (phase 1).

| Phase | What it does                                              | Status |
|-------|-----------------------------------------------------------|--------|
| 0     | In-process pipe — eliminates TCP                          | ✅     |
| 1     | Snapshot cache `directRead` — reads skip the event loop   | ✅ 240 µs on Moto G35 |
| 2     | SPSC ring buffer + `eventfd` — writes go lock-free        | ✅     |
| 3     | `io_uring` batch notify — 1 syscall per N commands        | ✅ (pipe fallback on kernels that SIGSYS on uring probe) |
| 4     | Worker pool — app→worker direct path, parallel reads      | ✅ SoC-aware default (2 on small-cores-only SoCs, 4 on big.LITTLE); 23 k retrievals/s @ p99 <1 ms |
| 5     | Typed JNI — `String[]` without RESP round-trip            | 🔨 partial |
| 6     | `suspend fun` SDK — coroutine-native Kotlin + Swift async  | ✅ Android + iOS mirrored |

### Auto-select

The dispatcher in `core/transport/dazzle_transport.c` probes in order:

1. `io_uring` (Phase 3) — only on Linux kernels with working
   `io_uring_setup`; on Android kernels without SECCOMP+uring the probe
   traps SIGSYS and the runtime falls back.
2. SPSC ring buffer + `eventfd` (Phase 2).
3. Plain pipe (Phase 0).

The caller doesn't choose: `DazzleConfig.transport = Transport.InProcess`
and the device decides which phase is active.

### Read path

Reads do NOT go through the write pipeline. `snapshot.h` exposes a
direct-read API that pulls from the Valkey Dict under an internal
read-lock, bypassing the AE event loop entirely.

On top of this, **Phase 4 (`core/transport/dazzle_worker_pool.c`)** adds
a pool of 2–4 worker threads that the Android/iOS SDK can dispatch
retrieval commands to directly, fronted by per-slot striped rwlocks
(`dazzle_slot_safe.h`). The worker pool is gated by
`DAZZLE_PARALLEL_READS=1`; when active, reads never touch the AE event
loop — the SDK enqueues into an MPSC ring, the worker pops, runs the
command against the Valkey Dict under the slot lock, and replies via
eventfd.

Critical fixes and optimizations in the worker pool path:
- **Fake-client `pending_write = 1` preset** — avoids the Valkey
  `putClientInPendingWriteQueue` race that deadlocked K≥4 concurrent
  callers (Blocker D).
- **Hot-command lookup cache** — atomic pointer array for the ~12 most
  common retrieval commands, skips the full command-table dispatch.
- **Stack-allocated argv** for `argc ≤ 16` — no alloc on the hot path.
- **Inline lean client reset** — skips unused `resetClient` bookkeeping
  that only matters for real TCP clients.
- **SoC-aware worker count** — on small-cores-only SoCs (no core ≥ 2.4
  GHz, detected from `/sys/.../cpuinfo_max_freq`), the pool caps at 2
  workers to avoid context-switch thrashing on phones like the Moto g35
  5G (Unisoc T760, max 2.21 GHz).

### SDK — suspend-native since Plan 06

`DazzleServer`, `HashKey`, `StreamKey`, etc. expose `suspend fun`
variants (Kotlin) and `async throws` (Swift) on top of the blocking
`directCommand` path. Coroutines dispatched on `Dispatchers.IO` can
saturate the worker pool without exhausting the Kotlin coroutine pool
threads, which was the root cause of the K=8 deadlock measured on
`feat/parallel-read-execution` before Plan 06 landed.

## Backends

The SDK exposes seven Dazzle context-manager variants, each
exercising a different storage / retrieval strategy:

| Backend                 | Strategy                                                     |
|---|---|
| `dazzle`                | Baseline — one HMGET per field, read-time aggregation        |
| `dazzle-lua`            | Server-side EVAL script aggregates                            |
| `dazzle-pipeline`       | PIPELINE batching of reads                                    |
| `dazzle-hfe`            | Hash Field Expiration — per-field TTL demo                    |
| `dazzle-hll`            | HyperLogLog — cardinality demo                                |
| `dazzle-precompute`     | Rolling window materialized at ingest; retrieval = 1 HMGET    |
| `dazzle-incremental`    | Delta-updated materialized state on each ingest (Plan 07)     |

`dazzle-incremental` is the current Pareto frontier: matches precompute
retrieval latency while eliminating precompute's write amplification.
The full multi-backend evaluation (P50/P95 latency, throughput,
ingest cost) is released alongside the paper.

## Versioning

- Valkey is a **dependency**, not in-tree source.
- Android pins via `FetchContent GIT_TAG` in `sdk/android/src/main/cpp/CMakeLists.txt`.
- iOS pins via `VALKEY_VERSION` in `sdk/ios/build.sh`.
- Patches live in `versions/<version>/patches/` (currently inline; see
  `versions/v9/patches/README.md` for the extraction plan).
- `ValkeyVersion` in the SDK config mirrors the build-time choice so
  callers can branch on features without reading CMake.

## Research layer

The paper-companion benchmark apps and analysis scripts (Gemma +
context injection, storage-only tests, multi-backend ablation) are
maintained in a separate repository scheduled to be released
alongside the paper. The shipped SDK in this repo contains only
the runtime code that consumers use.
