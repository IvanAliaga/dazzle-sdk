# SQLite Family Snapshot at N=200 (after 200 ingests)

| Backend | Retrieval avg (µs) | Ingest total (ms) | DB size after ingest (MB) |
|---|---:|---:|---:|
| sqlite | 1061.3 ± 104.0 | 251.95 ± 6.21 | 0.483 |
| sqlite-optimized | 899.4 ± 116.2 | 59.09 ± 1.92 | 0.483 |
| sqlite-precompute | 75.0 ± 15.3 | 207.77 ± 22.18 | 0.484 |


