# Table 15 with bootstrap 95% confidence intervals

Bootstrap method: percentile, paired-qid resampling for ratios.
`B = 10000`, seed = 42, n = 200 queries per cell.
Source JSON: `research/benchmarks/results/Moto_G35_5G/rag_2x2/rag_e2e_moto_g35_5G_1777395311213.json`
SHA-256 (verified): `00d21f6c8752ffaa1015624b69a5e5d0fd403670d72561e3838bdac0ab461e76`.

## Table 15a — Per-cell point estimates with 95 % CIs

| Configuration              | EM_short                  | EM_contains               | F1_short                  | F1_passage                |
|----------------------------|---------------------------|---------------------------|---------------------------|---------------------------|
| Qwen 0.5B (no RAG)         | 0.015 [0.000, 0.035] | 0.105 [0.065, 0.150] | 0.079 [0.055, 0.106] | 0.151 [0.138, 0.164] |
| Qwen 0.5B + Dazzle RAG     | 0.120 [0.080, 0.165] | 0.630 [0.565, 0.695] | 0.235 [0.191, 0.283] | 0.334 [0.300, 0.369] |
| Qwen 1.5B (no RAG)         | 0.045 [0.020, 0.075] | 0.110 [0.070, 0.155] | 0.118 [0.084, 0.154] | 0.085 [0.073, 0.098] |
| Qwen 1.5B + Dazzle RAG     | 0.310 [0.245, 0.375] | 0.735 [0.670, 0.795] | 0.487 [0.430, 0.543] | 0.235 [0.208, 0.265] |

## Table 15b — Bootstrap 95 % CIs on per-metric ratios

Paired-qid resampling: for each bootstrap iteration the **same**
draw of 200 query indices is used in both the numerator cell
and the denominator cell, so per-query correlation is preserved.
A `★` after the CI marks ratios where the 95 % CI does **not**
cross 1.0 — i.e. the directional effect is significant at the
conventional bootstrap-percentile level. A `⚠` flag marks
ratios where >0.5 % of bootstrap iterations had a denominator
mean of exactly 0; those iterations are dropped before the
percentile computation, but the ratio is statistically unstable
and should be read with the additive (risk-difference) numbers
from Table 15a as the primary reading.

| Ratio                                       | EM_short                  | EM_contains               | F1_short                  | F1_passage                |
|---------------------------------------------|---------------------------|---------------------------|---------------------------|---------------------------|
| Qwen 0.5B + RAG / Qwen 0.5B no-RAG          | 8.00× [3.00×, 29.00×] ★ ⚠ | 6.00× [4.19×, 9.71×] ★ | 2.97× [2.06×, 4.46×] ★ | 2.22× [1.96×, 2.49×] ★ |
| Qwen 1.5B + RAG / Qwen 1.5B no-RAG          | 6.89× [4.00×, 16.00×] ★ | 6.68× [4.66×, 10.86×] ★ | 4.13× [3.08×, 5.82×] ★ | 2.76× [2.32×, 3.33×] ★ |
| Qwen 0.5B + RAG / Qwen 1.5B no-RAG          | 2.67× [1.33×, 6.75×] ★ | 5.73× [4.07×, 9.00×] ★ | 2.00× [1.42×, 2.87×] ★ | 3.93× [3.34×, 4.63×] ★ |
| Qwen 1.5B + RAG / Qwen 0.5B + RAG           | 2.58× [1.82×, 4.06×] ★ | 1.17× [1.05×, 1.30×] ★ | 2.07× [1.74×, 2.53×] ★ | 0.70× [0.61×, 0.81×] ★ |

## Significance summary

Every reported ratio has a 95 % CI that excludes 1.0 — every
directional effect in Table 15 is significant at the
conventional bootstrap-percentile level.

Ratios flagged unstable (`⚠` — denominator-mean = 0 in >0.5 % of iterations):

- `small_rag` / `small_no_rag` on `em_short`: 8.00× [3.00×, 29.00×] (undefined fraction = 5.27 %). The denominator's
  base rate is too low for a stable multiplicative ratio at n = 200;
  the additive lift in Table 15a (mean − mean) is the better summary.

## Methodological note

Per-cell CIs are non-parametric percentile bootstrap on the
per-query metric arrays (n = 200 each). Ratio CIs use the same
resampling method but draw the **same** index vector for both
cells in each iteration (paired bootstrap), which is the
appropriate method when the two cells share queries — it
removes between-query variance from the ratio's standard error
and is therefore tighter (and correct) than two independent
bootstraps. Determinism: B = 10000, seed = 42; the
`--self-check` flag re-runs the pipeline twice and asserts the
output digests match before writing this file.
