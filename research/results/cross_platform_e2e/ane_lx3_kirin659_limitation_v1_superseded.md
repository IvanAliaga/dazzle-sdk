# ANE-LX3 (Kirin 659) — RAM-limited, excluded from §5.9 cross-platform run

## Verdict

**Excluded from the §5.9 RAG E2E table.** Kirin 659 SoC + 4 GB RAM cannot
host the full setup (BGE-small embedder + Qwen 2.5 0.5B + Qwen 2.5 1.5B
co-resident in app-private mmap) without the EMUI iAware governor freezing
the process before any variant marker is emitted.

This is a *physical* limitation of the device class (4 GB RAM, ARMv8.0
A53 cluster, EMUI freeze daemon), not a Dazzle bug. Per project policy
("Sin atajos en benchmarks"), the cell is reported as `n/a — RAM` rather
than fabricated or downgraded.

## Evidence captured 2026-04-30 02:30 UTC (device)

- pid 6162 launched 19:18:48 device-time, 4 h 27 min wall-clock at probe
- Last log line: `ANE progress: embed passage 1800/2000` at 19:40 device-time
- ~7 hours of zero progress between 19:40 and 02:30
- `top` snapshot:
  - `S  0.0  4.5  96:25.75 dev.dazzle.experiment.storage`
  - State `S` (sleeping), 0 % CPU, 46 threads all sleeping
  - `VmSize 4 571 884 kB` vs `VmRSS 176 224 kB` → 4.5 GB virtual mmap
    against 176 MB resident, i.e. the model files are mmap'd but never
    actually paged in
- Device-wide memory pressure:
  - `Mem: 3 874 000k total, 3 339 924k used, 534 076k free`
  - `Swap: 2 293 756k total, 416 292k used, 1 877 464k free`
  - 87 % RAM used, swap already engaged → system is thrashing before
    any decode happens
- EMUI iAware signature in earlier `dumpsys` excerpts: `WorkingsetPause`
  + `WorkingsetPauseCollect` against the Dazzle app uid

## Why we cannot patch around it

Four options were considered:

1. **A2 — `maxQueries=50` + skip large variants.** Would have produced
   only the small-model half of the table, useless for the small-vs-large
   comparison that §5.9 makes. Including it as a partial row would have
   leaked the worst-of-both-worlds: still RAM-pressured, still EMUI-frozen,
   and visibly inconsistent with every other row in the table.
2. **A3 — Wait longer.** Logs showed zero forward progress for 7 hours
   on a chip whose embed phase took ~25 min on the other devices. The
   process was not slow, it was paused.
3. **A4 — `android:largeHeap="true"` on the storage app.** Tried on the
   second pass: the storage app manifest did not have `largeHeap` set
   (only `experiment.backends` did). Adding it raised the JVM heap class
   from ~256 MB to the device-tier limit (Kirin 659 → 384 MB). Rebuild
   + reinstall + relaunch: bench reached `embed passage 1800/2000` in
   ~22 min (consistent with G30 / FRL-L23 ratio), then froze again at
   the same point — `top -n 2` showed `%CPU = 0.0` while
   `voluntary_ctxt_switches = 219 / 32 min` and
   `VmSize 4.6 GB / VmRSS 172 MB`. The process is alive but iAware-paused
   exactly when the embedder finishes and the small LLM mmap fires
   alongside the HNSW index build. **JVM heap was not the bottleneck —
   device-wide RAM pressure is.** Pre-launch state on this device:
   `Mem: 3 874 000k total, 167 MB free, swap 401 MB engaged`.
4. **A5 — Embedder lifecycle fix in `RagE2EBench.kt`.** Pre-embed all
   200 queries up front, close the embedder before the LLM phase,
   pass an `Array<FloatArray>` of pre-computed embeddings into
   `runVariantRag`. Frees ~140 MB of resident pages (BGE weights
   ~110 MB + compute buffer ~30 MB) before any LLM gets opened.
   Schema and per-query metrics unchanged. Tried on the third pass
   (largeHeap + embedder lifecycle): bench froze again at the same
   `embed passage 1800/2000` checkpoint with
   `voluntary_ctxt_switches = 228` static and `TIME+` not growing.
   The freeze occurs *before* the embedder-close code path runs —
   the bottleneck is the embed loop itself thrashing against the
   `/sdcard`-mmap'd LLMs that the resolver picked up (220 MB free
   pre-launch). The fix is real and benefits the other devices,
   but it cannot conjure RAM that isn't there.
5. **A1 (chosen) — Document as RAM-limited.** Honest cell, no harness
   workaround, no synthetic numbers. Three rounds of fixes shipped
   to the harness in the process; ANE-LX3 still cannot host the full
   §5.9 setup.

## Cross-platform coverage retained

The §5.9 table still spans both ARMv8 minor versions and three Cortex
microarchitectures, all on physical mid-range Android devices:

| Chip          | µarch   | ISA     | RAM   | Status            |
|---------------|---------|---------|-------|-------------------|
| Unisoc T760   | A76     | v8.2    | 6 GB  | done (paper data) |
| MTK Helio G80 | A75     | v8.2    | 4 GB  | done (FRL-L23)    |
| QCOM SD662    | A73     | v8.0    | 4 GB  | done (G30)        |
| HiSi Kirin 659 | A53    | v8.0    | 4 GB  | excluded (this)   |

The retained set already covers v8.2 (with `dazzle_v82.so`, A76 + A75)
and v8.0 (baseline `dazzle.so`, A73). Adding the A53 row is desirable
but not necessary for the cross-platform claim.

## §5.9 wording (when paper is updated)

> Among the four devices initially provisioned, the HiSilicon Kirin 659
> (4 GB RAM, ARMv8.0 A53 cluster) was excluded after seven hours of zero
> forward progress: the EMUI iAware governor froze the benchmark process
> at the end of the embedder phase, with `VmSize` 4.5 GB against
> `VmRSS` 176 MB and device-wide RAM utilisation at 87 %. We report this
> outcome as `n/a — RAM` rather than down-scope the harness, since a
> partial run would not be comparable with the other rows. The remaining
> three SoCs cover both ARMv8 minor revisions (`v8.2` via T760 + Helio G80
> with the `dazzle_v82.so` variant, `v8.0` via SD662 with the baseline
> `dazzle.so`) and three Cortex generations (A76, A75, A73).
