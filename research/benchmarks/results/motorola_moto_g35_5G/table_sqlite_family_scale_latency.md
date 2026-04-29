# SQLite Family N-Sweep — Latency

| Backend | N=200 retrieval (µs) | N=1000 retrieval (µs) | N=5000 retrieval (µs) | N=20000 retrieval (µs) |
|---|---:|---:|---:|---:|
| sqlite | 1061.3 ± 104.0 | 739.1 ± 6.8 | 717.4 ± 2.4 | 721.6 ± 2.0 |
| sqlite-optimized | 899.4 ± 116.2 | 508.1 ± 3.5 | 514.5 ± 10.6 | 505.4 ± 3.1 |
| sqlite-precompute | 75.0 ± 15.3 | 59.8 ± 1.7 | 62.1 ± 1.0 | 60.6 ± 3.2 |

| Backend | N=200 ingest total (ms) | N=1000 ingest total (ms) | N=5000 ingest total (ms) | N=20000 ingest total (ms) |
|---|---:|---:|---:|---:|
| sqlite | 251.95 ± 6.21 | 1260.01 ± 13.35 | 6050.76 ± 38.45 | 24029.95 ± 66.24 |
| sqlite-optimized | 59.09 ± 1.92 | 307.78 ± 9.57 | 1411.89 ± 66.57 | 5507.54 ± 177.71 |
| sqlite-precompute | 207.77 ± 22.18 | 874.04 ± 19.38 | 4106.64 ± 35.17 | 15947.99 ± 230.91 |


