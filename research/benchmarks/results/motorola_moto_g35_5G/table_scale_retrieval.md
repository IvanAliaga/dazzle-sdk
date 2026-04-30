## Table: Retrieval Latency vs N Readings

| Backend | N=200 | N=1000 | N=5000 | N=20000 |
|---------|------------|------------|------------|------------|
| **dazzle-precompute** | 69.5 µs | 28.9 µs | 29.0 µs | 63.8 µs |
| **inmemory** | 662.4 µs | 315.5 µs | 360.4 µs | 315.9 µs |
| **sqlite** | 1061.3 µs | 739.1 µs | 717.4 µs | 721.6 µs |
| **sqlite-optimized** | 899.4 µs | 508.1 µs | 514.5 µs | 505.4 µs |
| **sqlite-precompute** | 75.0 µs | 59.8 µs | 62.1 µs | 60.6 µs |
| **valkey** | 4559.3 µs | 4157.5 µs | — | — |
| **valkey-pipeline** | 3287.8 µs | 3030.6 µs | — | — |
| **valkey-precompute** | 1368.4 µs | 1275.5 µs | — | — |

