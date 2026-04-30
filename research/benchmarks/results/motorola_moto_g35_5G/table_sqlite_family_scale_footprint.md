# SQLite Family N-Sweep — Storage Footprint

| Backend | N=200 DB size after ingest (MB) | N=1000 DB size after ingest (MB) | N=5000 DB size after ingest (MB) | N=20000 DB size after ingest (MB) |
|---|---:|---:|---:|---:|
| sqlite | 0.483 | 0.484 | 0.495 | 0.510 |
| sqlite-optimized | 0.483 | 0.483 | 0.492 | 0.509 |
| sqlite-precompute | 0.484 | 0.487 | 0.495 | 0.509 |


