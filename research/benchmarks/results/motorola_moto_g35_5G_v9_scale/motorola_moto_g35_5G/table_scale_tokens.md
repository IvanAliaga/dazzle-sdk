## Table: Token Efficiency vs N Readings

| Backend | N=200 | N=1000 |
|---------|------------|------------|
| **inmemory** | ~64 | ~64 |
| **lmdb** | ~64 | ~64 |
| **sqlite** | ~64 | ~64 |
| **valkey** | ~64 | ~64 |
| **valkey-lua** | ~64 | ~64 |
| **valkey-pipeline** | ~64 | ~64 |
| **valkey-precompute** | ~62 | ~62 |

