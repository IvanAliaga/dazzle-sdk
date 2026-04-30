## Table: Ingest Throughput vs N Readings

| Backend | N=200 | N=1000 | N=5000 | N=20000 |
|---------|------------|------------|------------|------------|
| **dazzle-precompute** | 1214.2 µs | 1529.3 µs | 1180.6 µs | 1327.1 µs |
| **inmemory** | 12.0 µs | 7.0 µs | 3.7 µs | 2.8 µs |
| **sqlite** | 1259.7 µs | 1260.0 µs | 1210.2 µs | 1201.5 µs |
| **sqlite-optimized** | 295.5 µs | 307.8 µs | 282.4 µs | 275.4 µs |
| **sqlite-precompute** | 1038.8 µs | 874.0 µs | 821.3 µs | 797.4 µs |
| **valkey** | 2310.8 µs | 2129.8 µs | — | — |
| **valkey-pipeline** | 1779.9 µs | 1573.1 µs | — | — |
| **valkey-precompute** | 3841.2 µs | 3843.7 µs | — | — |

