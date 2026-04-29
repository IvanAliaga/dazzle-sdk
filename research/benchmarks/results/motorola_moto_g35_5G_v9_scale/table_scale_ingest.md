## Table: Ingest Throughput vs N Readings

| Backend | N=200 | N=1000 |
|---------|------------|------------|
| **inmemory** | 12.6 µs | 32.3 µs |
| **lmdb** | 982.8 µs | 946.5 µs |
| **sqlite** | 5486.0 µs | 2295.0 µs |
| **valkey** | 2369.9 µs | 2529.2 µs |
| **valkey-lua** | 1129.9 µs | 2880.7 µs |
| **valkey-pipeline** | 1069.9 µs | 2882.0 µs |
| **valkey-precompute** | 5373.1 µs | 7116.7 µs |

