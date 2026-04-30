## Table: Ingest Throughput vs N Readings

| Backend | N=200 | N=1000 | N=5000 | N=20000 |
|---------|------------|------------|------------|------------|
| **Dazzle** | 216.9 µs | 110.8 µs | 75.1 µs | 68.2 µs |
| **Dazzle-Precompute** | 322.3 µs | 169.3 µs | 132.5 µs | 124.0 µs |
| **InMemory** | 4.4 µs | 2.2 µs | 2.0 µs | 1.3 µs |
| **LMDB** | 58.8 µs | 51.8 µs | 23.6 µs | 16.7 µs |
| **SQLite** | 338.5 µs | 187.0 µs | 153.0 µs | 140.9 µs |
| **SQLite-Optimized** | 129.9 µs | 108.6 µs | 72.0 µs | 65.7 µs |

