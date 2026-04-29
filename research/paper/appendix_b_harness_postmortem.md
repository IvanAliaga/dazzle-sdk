# Appendix B — Bench Harness Post-Mortem (`SqliteBruteforceVector`)

This appendix documents a harness bug that propagated stale data
across vector-bench runs and silently corrupted the recall numbers
in Table 4 (`dazzle-vector` row at small N) and Table 11 (`sqlite_plain`
truth-source). The bug, the fix, why our existing tests missed it,
the asserts that catch it now, and a sweep of every other on-device
benchmark in `experiment/backends/android/` that shares the
"delete file before run" pattern, are all reported here so a
reviewer can audit the harness contract end-to-end without reading
git diffs.

## B.1 The bug

`experiment/backends/android/core/SqliteBruteforceVector.kt` is the
truth-source backend for the §5.8 recall-floor evaluation: every
candidate vector engine is compared against its top-k results, so
`SqliteBruteforceVector` *must* hold exactly the vectors of the
current configuration and nothing else.

Before commit `1e3d5f5` (2026-04-28), the class:

1. Opened the database via `SQLiteOpenHelper`. Android's
   `SQLiteOpenHelper.getWritableDatabase()` resolves the file path
   through `Context.getDatabasePath(name)`, which lives under
   `<context.dataDir>/databases/<name>.db` — **not** under
   `context.filesDir`.
2. Re-initialised between runs by deleting the file path
   `<context.filesDir>/<name>.db` (and its WAL/SHM siblings).

Those two paths point to two different directories, so the
"re-initialise" step deleted **a file that did not exist** while
the actual database under `<dataDir>/databases/<name>.db` kept
accumulating rows from every previous run and every previous
configuration of the current run.

### Observable effect

Every engine in the recall-floor measurement was scored against a
truth source whose vector pool grew monotonically. The recall the
harness reported was

```
recall_observed = N_current_config / N_total_seen_so_far
```

For the typical sweep grid `N ∈ {200, 1 k, 5 k, 20 k}` the engines
reported recall ≈ `0.111 / 0.146 / 0.317 / ≈1.0` instead of the
real `≈0.95–1.0` for every cell. Only the largest N looked correct,
because at that point the current configuration's 20 000 vectors
swamped the historical pool.

The same path bug also caused `dbFileSizeBytes()` to return `-1`
(the file at `filesDir/<name>.db` did not exist), which surfaced
as "not reported" for the `sqlite_plain` row of Table 11 in the
v1 draft of this paper.

## B.2 Lifetime

| Event                                                                 | Date       | Commit / Cause                 |
|-----------------------------------------------------------------------|------------|--------------------------------|
| Bug introduced when `SqliteBruteforceVector` migrated from raw `SQLiteDatabase.openOrCreateDatabase(filesDir/db, …)` to `SQLiteOpenHelper`.  | ~2026-04-15 | refactor commit (the `filesDir` cleanup path was carried forward unchanged from the pre-helper code) |
| Bug detected during Table 11 review when a reviewer asked why every engine's recall was suspiciously close to `N_cfg / N_total_so_far`. | 2026-04-27 | Manual data audit of the JSONs |
| Bug fixed.                                                            | 2026-04-28 | `1e3d5f5` — `Fix VectorBenchmark recall regression + report Dazzle/sqlite_plain DB sizes` |

The buggy data never appeared in the public paper; the v1 internal
draft tagged the affected cells as "suppressed" pending audit, and
the published Tables 4 / 11 / 12 in this revision are post-fix.

## B.3 Why existing tests did not catch it

`experiment/backends/android/test/` had a unit test for the SQL
schema (`CREATE TABLE … (id, vec)`) and a smoke test that opened
the DB, inserted a vector, and queried it back. Neither exercised
the **multi-run re-initialisation** that the recall-floor harness
relies on:

- The smoke test created a single DB inside `tmp_dir`, populated it,
  asserted, dropped `tmp_dir`. Single-run.
- The schema test never went through the `filesDir` path that the
  production harness uses.

Both tests thus passed with the broken cleanup code. The class's
behaviour under "re-initialise between runs of the same harness"
was untested — and the recall-floor harness depended on exactly
that behaviour.

## B.4 What catches it now

Three asserts in commit `1e3d5f5`:

1. **Path resolution unified.** Both the open path and the delete
   path now go through `context.getDatabasePath("<name>.db")` and
   its `-wal` / `-shm` / `-journal` siblings. They cannot diverge
   silently because they share a single `getDatabasePath` call.
2. **Belt-and-braces row wipe.** After `SQLiteOpenHelper.getWritableDatabase()`
   returns, the harness now executes `DELETE FROM vecs;` before
   the new configuration loads. If a future refactor reintroduces
   a path divergence, the rows still get wiped — the bug becomes
   a small slowdown at startup instead of a silent recall
   corruption.
3. **`db_file_bytes` is a regression sentinel.** The harness emits
   the on-disk file size for each configuration (sum of main + WAL
   + SHM + journal). A future regression that re-introduces row
   accumulation will surface as `db_file_bytes` growing
   monotonically across sweep configurations within a single
   bench launch — easy to flag in JSON post-processing without
   re-running the bench.

The post-fix run is archived at
`research/benchmarks/results/Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json`
(SHA-256 cited in §5.2) and its Table 4 / Table 11 cells are
reproduced by re-running the bench with the same `dim = 384,
k = 10, paper384_scale` preset.

## B.5 Audit of similar harnesses

Bug pattern: a class opens a database under one directory but its
"reset before run" code deletes a file in a different directory.
We grep every on-device benchmark in
`experiment/backends/android/` for `filesDir`, `cacheDir`,
`getDatabasePath`, and `.delete()` calls and check each occurrence
against its corresponding open path.

| File                                                  | Open path                                               | Delete path                                             | Same dir? | Notes                                                                                     |
|-------------------------------------------------------|---------------------------------------------------------|---------------------------------------------------------|:---------:|-------------------------------------------------------------------------------------------|
| `core/SqliteBruteforceVector.kt` (post-fix)           | `getDatabasePath("<name>.db")`                          | `getDatabasePath("<name>.db")` + WAL/SHM/journal        | ✓         | The fixed file. Belt-and-braces `DELETE FROM vecs` after open.                            |
| `core/SqliteVecVector.kt`                             | `File(context.filesDir, "<name>.db")` opened via raw `openOrCreateDatabase` | `File(context.filesDir, "<name>.db")` + WAL/SHM         | ✓         | Open and delete share `filesDir`; no `SQLiteOpenHelper` involved. **Not affected** by the bug pattern. |
| `core/SqliteVectorAiVector.kt`                        | `File(context.filesDir, "<name>.db")` opened via raw `openOrCreateDatabase` | `File(context.filesDir, "<name>.db")` + WAL/SHM         | ✓         | Same as `SqliteVecVector.kt` — consistent path. **Not affected**.                          |
| `core/HnswParityBench.kt`                             | `getExternalFilesDir(null) ?: filesDir` for **JSON output**, not a DB | n/a — output file, not deleted before run               | n/a       | Not a DB-style bench. Safe.                                                               |
| `core/VectorDimSweep.kt`                              | `File(context.filesDir, "<json>")` for output           | n/a                                                     | n/a       | Output JSON only. Safe.                                                                    |
| `core/VectorBenchmark.kt`                             | output JSON only                                        | n/a                                                     | n/a       | Safe.                                                                                     |
| `core/EmbedLatencyBench.kt`                           | `filesDir/embed/` for downloaded weights                | n/a — downloaded once, not deleted between configs      | n/a       | Safe.                                                                                     |
| `rocksdb/RocksDbContextManager.kt`                    | `File(context.filesDir, "rocksdb-experiment")`          | `dbDir.deleteRecursively()` on init                     | ✓         | Open and delete share `filesDir`. **Not affected**.                                       |
| `dazzle/Dazzle*Manager.kt` (six manager files)        | Dazzle SDK; persistence handled by `DazzlePersistence.Rdb` / `Ephemeral` | `FLUSHALL` between configs (added in `1e3d5f5`)          | n/a       | KV-engine, no Android `Context` file path involved. The Dazzle keyspace-isolation fix in `1e3d5f5` handles this. |

**Conclusion of the audit.** The
`SqliteOpenHelper.getDatabasePath` vs `filesDir` divergence is
specific to one class. The other two SQLite-family vector classes
(`SqliteVecVector`, `SqliteVectorAiVector`) avoid the bug pattern
by consistently using `filesDir` for both open and delete; the
RocksDB manager avoids it the same way; the rest of the
benchmarks emit JSON output rather than a database file and have
no reset-before-run requirement. No other on-device harness in
the repo carries a latent instance of this bug at the time of
this revision. The audit is reproducible from the grep query
documented in §B.4 of this appendix.

## B.6 Cross-references in the paper

- §5.2 cites the post-fix bench JSON
  (`vecbench_moto_g35_5G_1777369156656.json`, SHA pinned, commit
  `1e3d5f5`) as the source for Table 4 and Table 11.
- §5.8 inherits the same JSON for the operating-point comparisons.
- §6.3 cites this appendix in the limitations section as the
  authoritative record of the harness fix.
