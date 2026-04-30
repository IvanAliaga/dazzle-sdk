## Table: Concurrent Read-Write Retrieval Latency vs N

| Backend | N=200 | N=1000 | N=5000 | N=20000 |
|---------|------------|------------|------------|------------|
| **Dazzle** | 139.2 µs | 63.7 µs | 63.3 µs | 63.2 µs |
| **Dazzle-Precompute** | 25.4 µs | 17.8 µs | 17.8 µs | 17.8 µs |
| **InMemory** | 148.9 µs | 149.3 µs | 106.4 µs | 55.8 µs |
| **LMDB** | 167.4 µs | 67.2 µs | 46.9 µs | 85.8 µs |
| **SQLite** | 73.4 µs | 47.5 µs | 47.7 µs | 46.7 µs |
| **SQLite-Optimized** | 75.9 µs | 38.2 µs | 32.9 µs | 33.1 µs |

