# Vector Retrieval Benchmark — motorola moto g35 5G

Device: motorola moto g35 5G • run 2026-04-24T12:58:59.381615Z

Dim 384 mirrors modern embedding sizes (BGE-base, E5, OpenAI ada-002-trunc).
Results below are **p50 retrieval latency µs**, lower is better.
dazzle-vector / sq8 / f16 rows use ef_runtime=10 (best latency; recall in the second table).

**P50 search latency (µs)** — lower is better:

| N docs | sqlite-vector-ai | sqlite-vec | dazzle-vector | dazzle-sq8 | dazzle-f16 | dazzle-sq8+rerank |
|-------:|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| 500 | 149 | 1,082 | 77 | 54 | 91 | 67 |
| 2,000 | 378 | 4,158 | 190 | 73 | 142 | 116 |
| 10,000 | 1,604 | 13,491 | 275 | 179 | 274 | 300 |

**Recall@10** — closer to 1.000 is better:

| N docs | sqlite-vector-ai | sqlite-vec | dazzle-vector | dazzle-sq8 | dazzle-f16 | dazzle-sq8+rerank |
|-------:|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| 500 | 0.997 | 1.000 | 0.993 | 0.992 | 0.994 | 0.996 |
| 2,000 | 0.990 | 1.000 | 0.999 | 0.991 | 0.996 | 1.000 |
| 10,000 | 0.993 | 1.000 | 0.993 | 0.985 | 0.995 | 0.998 |

**Ingest time (ms)** — lower is better, dim=384:

| N docs | sqlite-vector-ai | sqlite-vec | dazzle-vector | dazzle-sq8 | dazzle-f16 | dazzle-sq8+rerank |
|-------:|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| 500 | 10 | 30 | 46 | 32 | 45 | 31 |
| 2,000 | 90 | 123 | 339 | 187 | 323 | 183 |
| 10,000 | 385 | 699 | 10,430 | 2,976 | 6,161 | 3,026 |

## Headline (dim=384, N=10 000)

Competitor: **sqlite-vector-ai** (1,604 µs, 0.993 recall).

Two recommended dazzle operating points — pick by your recall budget:

**Max speed** — dazzle-sq8 @ ef=10
- 179 µs / 0.985 recall@10 → **9× faster than sqlite-vector-ai**

**RAG-grade** — dazzle-sq8+rerank @ ef=10
- 300 µs / 0.998 recall@10 → **5.3× faster than sqlite-vector-ai** with near-perfect recall

Ingest (build a 10 000-passage index at dim=384):
- sqlite-vector-ai ingest = **385 ms**
- dazzle-sq8 ingest = **2,976 ms**; dazzle-sq8+rerank ingest = **3,026 ms**

For reference, sqlite-vec OSS (brute-force) on the same machine: 13,491 µs — dazzle-sq8 is **75× faster** than that too.
