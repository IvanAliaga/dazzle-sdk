# Vector Retrieval Benchmark — iPhone 12 Pro

Device: iPhone 12 Pro • run 2026-04-24T13:14:17Z

Dim 384 mirrors modern embedding sizes (BGE-base, E5, OpenAI ada-002-trunc).
Results below are **p50 retrieval latency µs**, lower is better.
dazzle-vector / sq8 / f16 rows use ef_runtime=10 (best latency; recall in the second table).

**P50 search latency (µs)** — lower is better:

| N docs | sqlite-vector-ai | sqlite-vec | dazzle-vector | dazzle-sq8 | dazzle-f16 | dazzle-sq8+rerank |
|-------:|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| 500 | — | 1,152 | 30 | 13 | 32 | 21 |
| 2,000 | — | 3,625 | 51 | 20 | 55 | 34 |
| 10,000 | — | 18,472 | 103 | 38 | 102 | 68 |

**Recall@10** — closer to 1.000 is better:

| N docs | sqlite-vector-ai | sqlite-vec | dazzle-vector | dazzle-sq8 | dazzle-f16 | dazzle-sq8+rerank |
|-------:|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| 500 | — | 1.000 | 0.983 | 0.908 | 0.980 | 0.998 |
| 2,000 | — | 1.000 | 0.921 | 0.872 | 0.914 | 0.958 |
| 10,000 | — | 1.000 | 0.829 | 0.776 | 0.857 | 0.878 |

**Ingest time (ms)** — lower is better, dim=384:

| N docs | sqlite-vector-ai | sqlite-vec | dazzle-vector | dazzle-sq8 | dazzle-f16 | dazzle-sq8+rerank |
|-------:|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| 500 | — | 47 | 24 | 16 | 25 | 15 |
| 2,000 | — | 186 | 238 | 128 | 245 | 130 |
| 10,000 | — | 1,037 | 4,511 | 1,720 | 4,411 | 1,757 |

## Headline (dim=384, N=10 000)

Competitor: **sqlite-vec** (18,472 µs, 1.000 recall).

Two recommended dazzle operating points — pick by your recall budget:

**Max speed** — dazzle-sq8 @ ef=10
- 38 µs / 0.776 recall@10 → **486× faster than sqlite-vec**

**RAG-grade** — dazzle-sq8+rerank @ ef=200
- 322 µs / 0.997 recall@10 → **57.4× faster than sqlite-vec** with near-perfect recall

Ingest (build a 10 000-passage index at dim=384):
- sqlite-vec ingest = **1,037 ms**
- dazzle-sq8 ingest = **1,720 ms**; dazzle-sq8+rerank ingest = **1,757 ms**
