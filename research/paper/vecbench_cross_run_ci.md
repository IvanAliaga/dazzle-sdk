# Table 11 headline cells with cross-run bootstrap 95 % CIs (Moto G35 5G)

Bootstrap method: cross-run percentile bootstrap on the p50 (and avg, side-table) search-latency statistic. Each bench run produced one (avg, p50, p95, p99) tuple over 100 queries; we bootstrap the **median of per-run p50s** across the 4 independent runs archived in `research/benchmarks/results/Moto_G35_5G/vector/`. `B = 10 000`, seed = 42.

**Method scope.** Per-run aggregates only — the legacy harness did not persist the 100-query latency array. The next-generation harness (`VectorBenchmark.kt::latencyStats` after this revision) emits the raw `latencies_us` array, so future revisions can replace this across-runs bootstrap with the tighter per-query bootstrap; we keep this script as the audit trail for the v2 paper measurements.

## Source bench JSONs

| File                                                           | timestamp                  | sha256 (prefix) |
|----------------------------------------------------------------|----------------------------|-----------------|
| `vecbench_moto_g35_5G_1777352750993.json` | `2026-04-28T05:05:50.981238Z` | `8132d6bd9e1959fe` |
| `vecbench_moto_g35_5G_1777353678296.json` | `2026-04-28T05:21:18.283211Z` | `9f656fa4eebe1325` |
| `vecbench_moto_g35_5G_1777368290558.json` | `2026-04-28T09:24:50.549381Z` | `b694f302298d905f` |
| `vecbench_moto_g35_5G_1777369156656.json` | `2026-04-28T09:39:16.645456Z` | `5a64d3692da166d9` |

## Table 11 headline cells (N = 20 000, dim = 384, k = 10)

| Engine                  | n runs | per-run p50 µs (each run)       | bootstrap p50 [95 % CI] (µs) | bootstrap avg [95 % CI] (µs) |
|-------------------------|-------:|---------------------------------|------------------------------|------------------------------|
| `dazzle_sq8            ` |      4 | [206, 212, 203, 208] | 207 [203, 212] | 218 [212, 222] |
| `objectbox             ` |      4 | [1078, 922, 1004, 853] | 963 [853, 1078] | 1070 [875, 1133] |
| `sqlite_vector_ai      ` |      4 | [3128, 3090, 3083, 3087] | 3088 [3083, 3128] | 3088 [3082, 3127] |

## Headline ratios (paired-run bootstrap on p50)

Each bootstrap iteration draws the same indices into the two engines' per-run-p50 lists. With small n the ratio CI is wide; the headline qualitative direction (HNSW < SIMD scan) is preserved across every iteration in every run pairing.

| Numerator vs denominator                          | ratio of medians [95 % CI] |
|---------------------------------------------------|----------------------------|
| Dazzle SQ8 / ObjectBox 4.x (HNSW vs HNSW)        | 0.21× [0.19×, 0.24×] |
| Dazzle SQ8 / SQLiteAI precompute (HNSW vs SIMD scan) | 0.07× [0.07×, 0.07×] |
| ObjectBox 4.x / SQLiteAI precompute              | 0.31× [0.28×, 0.34×] |
