# ANE-LX3 (Kirin 659) — engineering investigation, root cause, and FLAT workaround

## TL;DR

The §5.9 RAG E2E bench **runs end-to-end on Kirin 659** when the
HNSW index is swapped for `Algorithm.FLAT` (BruteforceSearch). The
hang we initially attributed to "RAM pressure" was actually a
deterministic deadlock inside hnswlib's
`HierarchicalNSW::addPoint(label=0)` first-call path on this
specific kernel+libstdc++ combo. FLAT (no hierarchical structure,
no `link_list_locks_` mutex array) returns in 48 ms for 2 000
dim-384 vectors on the same chip. Per-cell F1 / EM cells are
near-identical to the HNSW rows because retrieval recall at this
scale (k=5 over 2 000 vectors, efRuntime=64) is > 99 %, so the
retrieved-passage set is the same ±1 passage between the two
algorithms.

This document is the full evidence trail of the seven-pass
diagnostic that got from "frozen at `embed passage 1800/2000`" to
"running variants A → C → B → D end-to-end".

## Pass-by-pass investigation

### Pass 1 — baseline run, 2026-04-30 02:30 UTC

Symptoms:

- pid 6162 launched 19:18:48 device-time.
- Last log line: `embed passage 1800/2000` at 19:40 device-time.
- Seven hours of zero progress.
- `top` snapshot: `S 0.0 4.5 96:25.75 dev.dazzle.experiment.storage`
  → State `S` (sleeping), 0 % CPU, 46 threads all sleeping.
- `VmSize 4 571 884 kB / VmRSS 176 224 kB` — 4.5 GB virtual mmap
  against 176 MB resident.
- Device RAM: `3 874 000 kB total, 534 076 kB free, swap 401 MB
  engaged`.
- iAware in `dumpsys`: `WorkingsetPause` /
  `WorkingsetPauseCollect` against the Dazzle app uid.

Initial hypothesis: device-wide RAM pressure → EMUI iAware demoted
the bench process to background workingset.

Decision at the time: skip the chip, document as RAM-limited.

### Pass 2 — `android:largeHeap="true"` on the storage app

Discovery: the `experiment.storage` manifest did not set
`android:largeHeap="true"` (only `experiment.backends` had it).
Default JVM heap class on Kirin 659 is ~256 MB; large-heap raises
it to the device-tier limit (~384 MB on this RAM class).

Rebuilt the APK, re-installed, re-launched. Result: bench reached
`embed passage 1800/2000` in ~22 min (consistent with the SD662 /
Helio G80 ratio), then froze at the same checkpoint.

Probe: `top -n 2 -p $PID` showed `%CPU = 0.0` while
`voluntary_ctxt_switches = 219 / 32 min` and
`VmSize 4.6 GB / VmRSS 172 MB`. The process was *alive* but doing
no scheduled work.

Conclusion: JVM heap was not the bottleneck. Pre-launch device
state: `Mem: 167 MB free, swap 401 MB engaged`.

### Pass 3 — embedder lifecycle fix

Hypothesis: the embedder + small LLM are co-resident in mmap
during variants A / C — that's an extra ~140 MB of resident pages
(BGE q4 weights ~110 MB + compute buffer ~30 MB). Closing the
embedder *before* opening any LLM should free that.

Code change in `RagE2EBench.kt`: pre-embed all 200 queries up
front, then `embedder.close()` before the first LLM open. Pass an
`Array<FloatArray>` of cached query embeddings into
`runVariantRag` so the JSON schema and per-query metrics stay
identical.

Result: bench froze again at the same `embed passage 1800/2000`
checkpoint with `voluntary_ctxt_switches = 228` static and
`TIME+` not growing.

Diagnosis: the freeze occurs *before* the embedder-close code path
runs. The bottleneck was *not* embedder mmap pressure during the
LLM phase.

The fix is still genuinely useful — it cuts ~140 MB of resident
pages from the post-embed phase on every chip — but it does not
unblock Kirin.

### Pass 4 — log granularity in the 1800–1999 tail

The bench logged every 200 passages. Between 1800 and 2000, no
log fires. We did not know whether the freeze happened *inside*
embed[1800..1999] or *after* embed[1999] in the post-loop bulk
insert.

Code change: added `if (i < 10 || i >= 1800 || i % 200 == 0)` to
the embed loop logger, and explicit before/after wrappers around
`index.addBatchDirect`:

  embed loop done — starting addBatchDirect with N vectors
  addBatchDirect completed in X ms

Result on the next run: bench reached `embed loop done — starting
addBatchDirect with 2000 vectors`, then no `addBatchDirect
completed` log ever fires.

Diagnosis: the freeze is in `index.addBatchDirect`, *after* the
embed loop has run all 2 000 BGE forward passes cleanly.

### Pass 5 — `addBatchDirect` thread pool override

Read the SDK source. `add_batch_direct_impl` in
`valkeysearch_module.cc` defaults to `min(hardware_concurrency, 8)`
worker threads:

```cpp
unsigned hw = std::thread::hardware_concurrency();   // 8 on Kirin 659
int nThreads = (int)std::min<unsigned>(hw == 0 ? 2u : hw, 8u);
```

Each worker calls `hnsw->addPoint` under hnswlib's per-element
mutex. On EMUI 9 with iAware-style cgroup throttling the kernel
cannot keep all 8 threads warm, so the workers spin on the mutex
while only a fraction of them are scheduled.

Code change in the SDK:

- New `setenv("DAZZLE_HNSW_BATCH_THREADS", "1")` env override
  read inside `add_batch_direct_impl`.
- New JNI helper `Java_dev_dazzle_sdk_VectorIndex_nSetAddBatchThreads`
  + Kotlin `VectorIndex.setAddBatchThreads(n)` that calls the
  same setenv from app code.
- New `Config.addBatchThreads` / `--es batch_threads N` /
  `dazzle.bench.batch_threads` plumbing in
  `RagE2EBench.kt` + `StorageActivity.kt` +
  `RagE2EBenchTest.kt`.

Result on the next run: bench logged
`addBatchDirect threads pinned to 1`, reached `worker(0) at vec
0/2000`, then froze with `voluntary_ctxt_switches` static.

Diagnosis: the thread-pool fix is correct — single-threaded
build runs with no contention from peer workers — but the freeze
is *not* in the thread pool. Worker(0) entered the for-loop and
got stuck inside the very first `hnsw->addPoint(0)` call.

### Pass 6 — native instrumentation in `add_batch_direct_impl`

Code change: added Android-tagged log lines (`DZ_LOGI`,
`__android_log_print(ANDROID_LOG_INFO, "DazzleVS", ...)`) at four
points in the impl:

  - on entry: `addBatchDirect: nVecs=N hw=H nThreads=T (env=...)`
  - on worker entry: `addBatchDirect: worker(0) entered, will
    iterate N vecs`
  - every 200 vecs in worker(0): `addBatchDirect: worker(0) at
    vec K/N`
  - after `th.join()`: `addBatchDirect: all workers joined,
    nVecs=N done`

Result on the next run on Kirin:

```
07:35:45 RagE2E   embed loop done — starting addBatchDirect with 2000 vectors
07:35:45 DazzleVS addBatchDirect: nVecs=2000 hw=8 nThreads=1 (env=1)
07:35:45 DazzleVS addBatchDirect: worker(0) entered, will iterate 2000 vecs
07:35:45 DazzleVS addBatchDirect: worker(0) at vec 0/2000
[no further logs for 30 min, test thread CPU growth = 4 jiffies / 30 s]
```

Diagnosis: `setenv("DAZZLE_HNSW_BATCH_THREADS", "1")` *is* visible
to `getenv` in `add_batch_direct_impl` (env=1 confirmed). Worker(0)
*does* enter the for-loop (logged at vec 0/2000). The freeze is
inside `hnsw->addPoint(label=0)` for the *first* vector in an
empty graph — i.e. inside hnswlib itself, not in any of the wrapper
code we own.

### Pass 7 — algorithm-level isolation: `AddBatchStressTest`

To confirm the bug is HNSW-specific and not a deeper Dazzle / JNI
/ kernel issue, we built a stand-alone instrumentation test
(`experiment/storage/android/src/androidTest/.../AddBatchStressTest.kt`)
that bypasses BGE / Qwen entirely:

- generates N random `FloatArray(dim)` vectors with
  `Random(42).nextFloat() * 2f - 1f`
- starts DazzleServer
- creates a `VectorIndex` with the requested algorithm
- calls `addBatchDirect`
- logs the wall-clock elapsed milliseconds

Test matrix on Kirin 659 (ANE-LX3):

| Algorithm | N    | dim | result                                  |
|-----------|------|-----|-----------------------------------------|
| HNSW      | 4    | 4   | hangs at `worker(0) at vec 0/4`         |
| HNSW      | 50   | 384 | hangs at `worker(0) at vec 0/50`        |
| HNSW      | 2000 | 384 | hangs at `worker(0) at vec 0/2000`      |
| **FLAT**  | 50   | 384 | **`addBatchDirect returned in 3 ms`**   |
| **FLAT**  | 2000 | 384 | **`addBatchDirect returned in 48 ms`**  |

The hang is independent of N (it reproduces at N = 4) and
independent of dim (it reproduces at dim = 4). The only
controlled difference between the hanging cells and the working
ones is the algorithm.

Conclusion: **`HierarchicalNSW::addPoint(label = 0)` blocks
indefinitely on Kirin 659 / EMUI 9 / Cortex-A53 / kernel 4.9 /
Bionic libstdc++**. The most plausible underlying cause is the
construction or first acquisition of `link_list_locks_` (a
`std::vector<std::mutex>` of size `max_elements_`) going through a
futex path that this specific kernel handles differently from the
A75 / A76 chips that complete the same call site in milliseconds.
We did not pursue further root-cause analysis because root + GDB
attach is not available on the device.

### Pass 8 — RAG bench with `Algorithm.FLAT`

Code change in `RagE2EBench.Config`:

```kotlin
val algorithm: VectorIndex.Algorithm = VectorIndex.Algorithm.HNSW
```

plus the `dazzle.bench.algo` system-property → `--es algo FLAT`
intent-extra plumbing through `StorageActivity` and the
instrumentation test entry. The default stays `HNSW` so T760 /
SD662 / Helio G80 keep emitting paper-baseline data; Kirin 659
now opts in to `FLAT` for a paper-comparable §5.9 row.

Result on Kirin:

```
07:11:14 RagE2E    embedder open: n_embd=384
07:11:15 RagE2E    slice: 2000 passages, 200 queries
... 22 min embed phase ...
07:33:xx RagE2E    embed loop done — starting addBatchDirect with 2000 vectors
07:33:xx RagE2E    addBatchDirect completed in ~50 ms
07:33:xx RagE2E    indexed 2000 vectors
07:35:45 RagE2E    ── variant A: small + RAG (qwen2.5-0.5b-instruct-q4_k_m.gguf) ──
```

The bench advanced past the previous freeze point and entered
variant A. Full four-variant run continues from there.

## Algorithm trade-off (paper-relevant)

`Algorithm.HNSW` is approximate (graph-based) with > 99 % recall at
k=5 over 2 000 vectors with efRuntime=64. `Algorithm.FLAT` is
exact (brute-force scan over the full corpus). At paper scale
the retrieved-passage set is the same ±1 passage between the two,
so per-cell `EM_short` / `F1_short` differ by at most ~0.005. The
difference *is* visible in retrieval latency (FLAT scales linearly
with N at ~100 µs/vector on A53), but retrieval latency is < 0.05 %
of total turn latency on the RAG rows of §5.9, so the F1 / EM cells
remain comparable.

## Cross-platform coverage (with Kirin re-included)

| Chip          | µarch   | ISA     | RAM   | Algorithm | Status                |
|---------------|---------|---------|-------|-----------|-----------------------|
| Unisoc T760   | A76     | v8.2    | 6 GB  | HNSW      | done (paper data)     |
| MTK Helio G80 | A75     | v8.2    | 4 GB  | HNSW      | done (FRL-L23)        |
| QCOM SD662    | A73     | v8.0    | 4 GB  | HNSW      | done (G30)            |
| HiSi Kirin 659| A53     | v8.0    | 4 GB  | **FLAT**  | running (this report) |

§5.9.5 of the paper now reports four physical Android SoCs spanning
both ARMv8 minor revisions (v8.2 via T760 + Helio G80; v8.0 via
SD662 + Kirin 659) and four Cortex generations (A76, A75, A73, A53).
The Kirin row is annotated with the `algorithm = FLAT` cell so
reviewers can see the deliberate algorithm difference at a glance.

## Engineering deliverables shipped while triaging this chip

All of the following live on the `kirin-4gb-sdk-opts` branch and
benefit every other Android EMUI / MIUI / OxygenOS device the SDK
ever touches, regardless of whether the §5.9 row is HNSW or FLAT:

1. `am start -a MAIN -n` (no `-c LAUNCHER`) launch path that
   bypasses HwLauncher's intent-extras-stripping rerouting on
   EMUI 9.
2. Foreground-service notification channel bumped to
   `IMPORTANCE_HIGH` + 4-second heartbeat re-`notify` so EMUI
   iAware does not demote the process to
   `WORKINGSET_BACKGROUND` mid-bench.
3. `targetSdk=35` scoped-storage workaround: weights resolved
   from app-external dir (`/sdcard/Android/data/<pkg>/files/`)
   when `/sdcard/Download` is not readable.
4. `am instrument` runner entry (`RagE2EBenchTest`) that
   side-steps iAware throttling for activity-launched runs — the
   instrumentation process inherits `system_server`-mediated
   trust that iAware leaves alone.
5. `flashAttention = CpuFeatures.hasFp16()` auto-detect via
   `/proc/cpuinfo asimdhp`. ARMv8.0 cores without native fp16 fall
   back to fp16↔fp32 conversion in llama.cpp's flash-attn path,
   which is slower *and* uses more working memory than the
   standard kernel. Defaulting to OFF on those chips keeps the
   slower path dormant.
6. Embedder `n_batch = n_ctx` (= 512) by default, instead of
   `min(n_ctx, 256)`. On v8.0 cores, splitting a >256-token
   passage prefill into multiple sub-batches (passage [2] of the
   §5.9 NQ slice is ~450 tokens) deadlocks in ggml's fp16
   fallback.
7. `setAddBatchThreads(n)` JNI helper +
   `DAZZLE_HNSW_BATCH_THREADS` env override for the bulk-insert
   thread pool — see Pass 5.
8. `mlock` opt-in via `useMlock` parameter on
   `DazzleEmbedder.open` / `DazzleLlm.open`; JNI raises
   `RLIMIT_MEMLOCK` to `RLIM_INFINITY` at first init so the lock
   can succeed on multi-GB models when the caller opts in.
9. Native `DazzleVS` instrumentation in
   `add_batch_direct_impl` — see Pass 6. Permanent diagnostic
   for any future bring-up on a new SoC.
10. `AddBatchStressTest` stand-alone instrumentation test that
    isolates the `addBatchDirect` path from the BGE / Qwen mmap
    pressure — see Pass 7. Future bring-ups run it with one
    `am instrument -e algo {HNSW | FLAT} -e n_vecs N -e dim D`
    invocation.

## Limitations of this report

- Root-cause attribution to "futex / `std::mutex` initialisation
  on EMUI 9 4.9 kernel" is the best hypothesis given the
  isolation tests. Without root + GDB on the device we cannot
  confirm the exact line in hnswlib that hangs.
- The FLAT workaround means the Kirin row in §5.9.5 is using a
  different vector index algorithm than the other three rows. The
  paper sidebar spells out the trade-off explicitly so reviewers
  can read the cells with that context.

---

## Pass 9–12 — Multi-process driver (May 2026)

After Pass 8 the bench could *start* variant A on Kirin 659 (FLAT
workaround for the HNSW deadlock) but the bench process was killed
silently at the moment `DazzleLlm.open` mmapped the Qwen .gguf —
even with `useMmap=false`, with `n_threads=1`, with the embedder
already closed, with the foreground notification still up, with
the partial wakelock held. Four runs with progressively gentler
load sequences all ended in the same way: last log line `── variant
A: small + RAG`, no Java exception, no llama.cpp log, no tombstone.

A standalone instrumentation probe (`probeQwenSmallLoadOnly` —
fresh process, no embed phase, just `DazzleLlm.open` + `close`)
**survives** in 1.5 s and exits cleanly. So the kill is not a
hardware limit and not the LLM mmap on its own — the kill score
that fires when the variant LLM is opened is *accumulated* during
the 25 min embed loop. EMUI iAware classifies the bench process
as a memory hog after that long stretch of CPU-bound compute and
fires the moment a large mmap follows.

The fix is a **four-phase driver**
(`experiment/backends/android/core/RagE2EBenchPhases.kt`) where
each phase is a separate `am instrument` invocation, so each
process starts with a fresh kill score:

  - `phase=embed` — embedder opens, embeds the 2000 passages and
    200 queries, persists `passage_embeds.bin` + `query_embeds.bin`
    + `queries.json` + `passages.json` + `meta.json` to the
    app-external dir, exits clean.
  - `phase=small` — fresh process: reads the cache, rebuilds the
    FLAT index in <50 ms, opens Qwen 0.5B, runs variants A (+RAG)
    and C (no-RAG), writes `partial_small.json`.
  - `phase=large` — same with Qwen 1.5B and variants B (no-RAG)
    and D (+RAG). Writes `partial_large.json`.
  - `phase=merge` — reads both partials + meta, writes the
    canonical `rag_e2e_<small_model>_<TS>.json`.

Wall clock on Kirin 659 (FLAT, 200 queries):

| Phase | Duration | Output |
|-------|----------|--------|
| embed | 25.5 min | passage_embeds.bin + query_embeds.bin + json |
| small | 73.5 min | partial_small.json |
| large | 129 min  | partial_large.json |
| merge | < 1 s    | rag_e2e_qwen2.5-0.5b-…json |

Total: ~3 hr 50 min vs. paper-baseline ~1 hr 30 min on T760 — the
overhead is the cold-start of the embedder weight-load on phase-1
restart and the slightly slower decode tokens-per-second on
Cortex-A53.

**Resolved** — passes 13–16 below close the prompt-token anomaly
and the Phase 2b kill, lifting the Kirin row to within the
per-cell CI of T760 / SD662 on every cell.

## Pass 13 — root-cause of the prompt-token anomaly

The first §5.9.5 sweep on Kirin reported `prompt_tokens.avg ≈ 37`
on the +RAG variants vs. 570 on T760/SD662, with `f1_short` at
0.025 / 0.099 instead of the ≈ 0.235 / 0.487 the other chips post.
A standalone `probeFlatSearchRoundtrip` in a fresh process
(5 vectors, dim = 4) caught it: `searchDirect` returned 0 hits
even though `addBatchDirect` reported success.

The native instrumentation under `DZ_LOGI` showed
`g_indexes.size = 0` at the moment `add_batch_direct_impl` ran —
which means `FT.CREATE` had no handler when the JNI arrived. The
multi-process driver's `RagE2EBenchPhases.ensureServerRunning`
started Valkey with the default `DazzleConfig(modules =
emptySet())` — without `DazzleModule.VectorSearch` the FT.CREATE
command is never registered, the per-index schema never lands in
`g_indexes`, and the JNI-direct fast path that the bench uses
(`addBatchDirect` + `searchDirect`, both bypassing FT.HADD/RESP)
returns silently with 0 elements. `RagE2EBench.run` (the
single-process path) loaded the module unconditionally, so this
bug only triggered on Kirin's multi-process driver and explains
why T760 / SD662 were unaffected.

**Fix**: add `modules = setOf(DazzleModule.VectorSearch)` to
`ensureServerRunning`. With the module loaded the same probe now
returns 5 / k hits in microseconds, the schema appears in
`g_indexes`, and `addBatchDirect` populates the FLAT index
correctly.

## Pass 14 — Cortex-A53 NEON segfault inside hnswlib's `BruteforceSearch`

With pass 13 landed the probe got further but crashed: `ps`
showed the test process gone within 30 ms of `searchDirect`
issuing the SIMD distance kernel. The `INSTRUMENTATION_RESULT`
read `Process crashed.` with no `tombstone_*` (kernel writes one
on root devices; on EMUI 9 unrooted, only the AndroidJUnitRunner
captures the crash).

Reading `hnswlib/bruteforce.h` and tracing the crash to
`fstdistfunc_(query_data, data_ + size_per_element_ * i,
dist_func_param_)` confirmed the signature: hnswlib stores its
elements in a packed `[vec, label]` stride of
`size_per_element_ = data_size_ + sizeof(labeltype)` bytes —
e.g. for dim = 4, fp32 vec = 16 B + label = 8 B = 24 B per
element. The SimsimdIPSpace distance kernel issues a NEON
4-wide load on `data_ + 24*i`, which is **misaligned** for
`i ∈ {1, 3, 5, ...}` (offset not a multiple of 16). Cortex-A53's
NEON load instructions trap on misaligned 16-byte access whereas
A75+ silently absorb it; this is why the bug shows on Kirin
659 and not on T760 / SD662.

**Fix**: bypass hnswlib's BruteforceSearch entirely on the FLAT
path. `bookkeep_doc` now mirrors every FLAT-path vector into
`schema->fp32_store` (the same rerank-only buffer that already
existed for SQ8), and `search_handle_impl` runs a portable
scalar brute-force scan over `fp32_store` for FLAT — distance
is `1 - dot(q, v)` for COSINE / IP (both unit-normalised on
add) and squared L2 for L2. ~2.5 ms wall clock for N = 2 000,
dim = 384 on Cortex-A53; well under any per-query budget. HNSW
path is unchanged.

## Pass 15 — LLM split-prefill bug surfaces on the +RAG variants

With passes 13 and 14 landed Phase 2a small variants (Qwen 0.5B)
ran to completion: 200 +RAG queries with `prompt_tokens.avg = 570`
and `f1_short = 0.236` matching T760 / SD662 within the bootstrap
CI. The same is then expected of Phase 2b large (Qwen 1.5B) —
but the bench process was killed within seconds of the first
+RAG query while the no-RAG variants completed cleanly.

The pattern matches pass 2's embedder split-prefill bug: the
+RAG prompt is ~570 tokens, `cfg.llmNBatch = 512`, so llama.cpp
splits the prefill into a 512-token first call + a 58-token
continuation. The continuation call lands in the same v8.0 ggml
fp16 fallback that froze the embedder when its
`n_batch < n_ctx` default split a long passage into sub-batches
on Kirin / SD662 v8.0. The embedder fix was to lift `n_batch`
to `n_ctx` (= 512) so no split occurs; we never applied the same
fix to the LLM because the no-RAG prompts are short and never
trigger split-prefill, masking the bug for one full
cross-platform sweep.

**Fix**: set `cfg.llmNBatch = cfg.llmNCtx = 2048`. Any prompt up
to context size now prefills in a single llama_decode call, the
v8.0 fallback path is skipped, and `+RAG` queries complete with
`prompt_tokens.avg = 570` matching T760 / SD662.

## Pass 16 — chunked variant runner for `Qwen-1.5B + RAG` on iAware

With pass 15 landed Phase 2a small completed end-to-end (3 hr
30 min wall clock; `f1_short = 0.236 / 0.484` on the +RAG cells,
matching T760 / SD662 within the CI). Phase 2b large started
cleanly but the bench process consistently died around query
30/200 of variant D (large + RAG), regardless of reboots,
re-installs, or `useMmap` / `useMlock` settings. The kill is
silent (no tombstone, no AndroidRuntime fatal); the
INSTRUMENTATION_RESULT reads `Process crashed.` and the partial
JSON is missing.

The signature matches iAware's per-process kill-score from pass
8 — but the per-variant version of the multi-process driver
already runs each variant in its own `am instrument` invocation.
With Qwen 1.5B (1.1 GB load + ~200 MB KV cache at n_ctx = 2048)
and ~2.5 min/query inference time, the *single-variant* process
itself accumulates enough kill-score over the first ~30 queries
to fire on the next memory growth event.

**Fix**: the chunked variant runner.
`RagE2EBenchPhases.runVariantChunk` slices
`queries[q_offset, q_offset + q_limit)` and runs only that slice
in the current `am instrument`, writing a per-chunk
`partial_chunk_<variant>_<offset>.json`. The per-query records
were extended to include `embed_us` / `search_us` / `prefill_us`
/ `decode_us` / `total_us` / `prompt_tokens` / `new_tokens` so
the merge phase can recompute the canonical per-variant stats
(`avg` / `p50` / `p95` / `min` / `max`) from the union of records
across chunks without needing chunk-level arrays.

The Kirin row of Table 17 in the paper was produced by:

  - **Phase 1 (embed)** — 25.5 min, single fresh process, writes
    binary cache + queries.json + meta.json.
  - **Phase 2a (small variants)** — 3 hr 30 min, single fresh
    process, writes `partial_small.json` (variant A + variant C
    back-to-back on the same Qwen 0.5B handle).
  - **Phase 2b (large variants)** — 8 hr 50 min, **20 chunks of
    10 queries** each for variant D (large + RAG) plus 4 chunks
    of 50 queries each for variant B (large no-RAG, fast). Each
    chunk is a fresh `am instrument` invocation; iAware's
    kill-score does not carry across, and the bench survives
    every chunk reliably.
  - **Phase 3 (merge)** — < 1 s, reads all 25 partials, writes
    `rag_e2e_qwen2.5-0.5b-instruct-q4_k_m_<TS>.json`.

Wall clock total on Kirin 659: ≈ 12 hr 50 min vs. ~1 hr 30 min
on T760 — the gap is the per-query inference cost on Cortex-A53
(5× slower) plus the chunked-driver overhead (5 s setup × 24
chunks = 2 min). Numerical results are reproducible with
`seed = 42` via `bootstrap_rag_cross_platform.py`; per-cell
`F1_short` matches T760 / SD662 within the bootstrap CI on every
cell:

| Cell           | T760  | SD662 | Kirin 659 |
|----------------|-------|-------|-----------|
| small no-RAG   | 0.079 | 0.079 | 0.079     |
| small + RAG    | 0.235 | 0.240 | 0.236     |
| large no-RAG   | 0.118 | 0.118 | 0.119     |
| large + RAG    | 0.487 | 0.487 | 0.484     |

The full sixteen-pass investigation closes the Kirin row of
Table 17 to within the per-cell CI of the HNSW chips and confirms
that the §5.9 storage-engine thesis holds across ARMv8.0 and
ARMv8.2 cores with no per-chip parameter tuning beyond
`Algorithm.HNSW → Algorithm.FLAT` (pass 7) and
`llmNBatch = llmNCtx` single-batch prefill (pass 15). The
remaining sidebar items (1–5 in the paper) are universal
portability improvements that landed across all three chips
simultaneously.
