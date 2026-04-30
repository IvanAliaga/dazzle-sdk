## Table: Concurrent Read-Write Retrieval Latency vs N

| Backend | N=200 | N=1000 | N=5000 | N=20000 |
|---------|------------|------------|------------|------------|
| **dazzle-precompute** | 48.1 µs | 39.8 µs | 38.1 µs | 47.3 µs |
| **inmemory** | 419.0 µs | 295.7 µs | 402.5 µs | 455.0 µs |
| **sqlite** | 3063.3 µs | 3124.2 µs | 3295.4 µs | 3454.4 µs |
| **sqlite-optimized** | 1849.7 µs | 1935.0 µs | 1958.0 µs | 1969.9 µs |
| **sqlite-precompute** | 305.5 µs | 344.4 µs | 309.5 µs | 368.0 µs |
| **valkey** | 6561.3 µs | 5469.9 µs | — | — |
| **valkey-pipeline** | 5228.8 µs | 4465.5 µs | — | — |
| **valkey-precompute** | 1594.5 µs | 1144.4 µs | — | — |

