## Table: Retrieval Latency vs N Readings

| Backend | N=200 | N=1000 |
|---------|------------|------------|
| **inmemory** | 2891.7 µs | 4986.4 µs |
| **lmdb** | 7378.0 µs | 2720.5 µs |
| **sqlite** | 6691.7 µs | 2144.0 µs |
| **valkey** | 11767.1 µs | 10479.0 µs |
| **valkey-lua** | 6628.0 µs | 4603.9 µs |
| **valkey-pipeline** | 9349.7 µs | 9012.1 µs |
| **valkey-precompute** | 1722.4 µs | 798.4 µs |

