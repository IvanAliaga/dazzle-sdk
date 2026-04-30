## Table: Concurrent Read-Write Retrieval Latency vs N

| Backend | N=200 | N=1000 |
|---------|------------|------------|
| **inmemory** | 4861.1 µs | 5583.3 µs |
| **lmdb** | 6647.3 µs | 5892.3 µs |
| **sqlite** | 7814.7 µs | 5361.1 µs |
| **valkey** | 8904.2 µs | 10060.1 µs |
| **valkey-lua** | 6320.1 µs | 4239.5 µs |
| **valkey-pipeline** | 7745.4 µs | 7464.1 µs |
| **valkey-precompute** | 1307.5 µs | 1707.8 µs |

