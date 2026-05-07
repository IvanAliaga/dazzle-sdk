# Performance

Headline numbers + the methodology behind them. Full data and
statistical treatment live in the research paper under
`research/paper/`; this document is the operational summary.

## Headline (Moto G35 5G — dim=384, N=10,000)

| Operation | Dazzle | sqlite-vector | Speedup |
|---|---|---|---|
| Vector search (top-k=10, ef=50, recall@10=0.95) | **0.4 ms** | 3.6 ms | **9×** |
| HSET round-trip (RESP path) | ~95 µs | n/a | — |
| HGET-all snapshot fast path | ~30 µs | n/a | — |

Same numbers reproduce on iPhone 12 Pro (A14) within 10%. iOS
benefits from a slightly faster L1 → L2 cache transition; Android
benefits from larger DRAM bandwidth on the same SoC class.

## Why Dazzle is fast — sources of speedup

In rough order of impact:

1. **In-process embedding.** No TCP, no Unix socket, no IPC. The
   command queue is a lock-free MPSC ring buffer in the same
   address space; the cost is a memory-fence on push + dequeue.
2. **Snapshot fast path.** `*Direct()` reads bypass the command
   queue entirely. They take a per-key shared lock and read the
   underlying `dict.c` pointer the writer thread also writes
   through. A typed C function returns the result to JNI / FFI
   without ever serialising to RESP.
3. **Post-link opcode rewriting on Android.** The ARMv8.2-a
   (FP16) build of `libdazzle_v82.so` ships with FMLA H-half
   instructions. On chips without `asimdhp` (Cortex-A53 / A55 /
   A73 — Snapdragon 662, Kirin 659, MediaTek Helio G80) the SDK
   intercepts `SIGILL` at runtime and emulates the instruction.
   Saves the cost of shipping a per-feature build.
4. **SIMSIMD distance dispatch.** Distance functions
   (`fp16_dot`, `int8_dot_sq8`) dispatch at startup to the best
   available SIMD path (NEON / NEON-FP16 / SDOT / scalar). The
   dispatcher itself is one indirect call after init.
5. **Multi-target ARM build.** Two ARM64 binaries ship in the
   same APK: a generic `armv8-a` baseline and an
   `armv8.2-a+fp16+dotprod` build. `DazzleNativeLoader.kt` reads
   `/proc/cpuinfo` once on startup and selects the right one.

## Methodology

The benchmark harness lives at
`research/benchmarks/`. Numbers in the paper come from the same
harness runs on the two reference devices (Moto G35 5G + iPhone 12
Pro).

### Reference devices — why these two

The
[paper-devices](https://github.com/IvanAliaga/dazzle-sdk/blob/main/research/paper/devices.md)
constraint is intentional: simulator and emulator results are too
noisy to publish, and high-end devices (Pixel 8 Pro, iPhone 15)
exaggerate the speedups. Moto G35 5G and iPhone 12 Pro are
mid-range mainstream devices that represent realistic deployment
hardware.

For internal experimentation we run on more devices (Pixel 6,
iPhone SE 3, Snapdragon 7 Gen 1 reference boards), but only the
two reference devices end up in publishable tables.

### What we measure

Each benchmark runs:

1. **Cold start** — boot the SDK from scratch, time first call.
2. **Steady state, p50** — median of 1000 calls after warmup.
3. **Steady state, p95** — useful for retrieval-pipeline budgets
   that need tail-latency guarantees.
4. **Recall** — for vector search, the fraction of true k-NN
   results returned, evaluated against an exact (brute force)
   reference computed once per dataset.

We do **not** report:

- Throughput in the form of "Dazzle does X queries per second".
  Single-thread throughput is `1 / latency` and depends on the
  workload mix — it conflates more than it informs.
- Energy / battery numbers. We have them internally but the
  measurement equipment (Monsoon HV) is hard to reproduce, so
  they're not in the paper.

### Statistical treatment

Each datapoint is the median of N=1000 trials with the harness
discarding the first 100 (warmup). Confidence intervals come from
percentile bootstrapping with B=10,000 resamples. The paper
reports 95% CIs on every claim that compares Dazzle to a
non-Dazzle baseline.

## Lite runtime (web / desktop)

Performance numbers from the lite runtime aren't in the paper
because the WASM and native lite builds are recent (1.0.0-beta.5).
Order-of-magnitude observations from manual testing:

- **Hash KV** in WASM: ~20 µs per HSET, ~10 µs per HGET. JS-side
  overhead (UTF-8 marshalling, ccall dispatch) dominates the C++
  side.
- **Vector search** in WASM: ~5× slower than native at N=10,000 /
  dim=384 due to lack of SIMD intrinsics. We expose
  `WASM_SIMD=1` builds in dev but the upstream Emscripten still
  has friction with NEON-equivalent intrinsics in hnswlib —
  shipping one build for now.
- **Native lite**: within 10% of the mobile build at the same
  workload, since both link the same hnswlib binary.

## When you suspect Dazzle isn't pulling its weight

A few diagnostic moves:

1. **Are you using `*Direct()` reads?** The default `HashKey.get`
   goes through RESP. If you're hot-pathing reads, switch to
   `getAllDirect` / `searchDirect` / `rangeByScoreDirect` /
   `membersDirect` / `getDirect`.
2. **Profile, don't guess.** The native SDK exposes
   `dazzle_metric_*` symbols that count distance computations and
   hops; the sample apps surface them through the bench harness.
3. **Check the loader.** On Android, log
   `DazzleNativeLoader.lastSelected()` — if it reports the
   baseline build (`libdazzle.so`) on a device you expected to be
   ARMv8.2, FP16 path won't run. Override via
   `dazzle.force_native_variant=v82` for an A/B.
4. **Grep `research/benchmarks/results/`.** If your workload
   matches a documented one, compare to the recorded numbers.
   Order-of-magnitude misses usually mean a config issue
   (HNSW `M` too low, `ef` too low, snapshot fast path bypassed).

## Pointers

- Paper: `research/paper/` (English + Spanish, arXiv-ready).
- Benchmark scripts: `research/benchmarks/`.
- Per-target results: `research/benchmarks/results/`.
- Sample apps with surfaced metrics: `samples/_scripts/_test_results/`.
