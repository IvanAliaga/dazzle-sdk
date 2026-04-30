## Table: Token Efficiency vs N Readings

| Backend | N=200 | N=1000 | N=5000 | N=20000 |
|---------|------------|------------|------------|------------|
| **dazzle-precompute** | ~30 | ~30 | ~30 | ~49 |
| **inmemory** | ~64 | ~64 | ~64 | ~82 |
| **sqlite** | ~64 | ~64 | ~64 | ~82 |
| **sqlite-optimized** | ~64 | ~64 | ~64 | ~82 |
| **sqlite-precompute** | ~64 | ~64 | ~64 | ~82 |
| **valkey** | ~64 | ~64 | — | — |
| **valkey-pipeline** | ~64 | ~64 | — | — |
| **valkey-precompute** | ~62 | ~62 | — | — |

