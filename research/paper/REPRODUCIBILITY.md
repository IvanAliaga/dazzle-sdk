# Reproducibility Guide (Paper v2)

This document maps the paper's empirical claims to scripts and data
in this repository so reviewers can reproduce the main tables and
metrics. **Source of truth: `research/paper/paper_v2_en.md`.** If
the markdown changes, the LaTeX build (`arxiv-build/`) must be
regenerated before any number drifts.

## 1) Environment and layout

| Path                                         | What                                  |
|----------------------------------------------|---------------------------------------|
| `research/paper/paper_v2_en.md`              | Paper source (markdown)               |
| `research/paper/arxiv-build/`                | LaTeX build dir (paper.tex, body.tex, refs.bib, paper.pdf) |
| `research/paper/COMPETITORS.md`              | Vendor naming source-of-truth         |
| `research/scripts/`                          | Bench launchers + analysis            |
| `research/benchmarks/results/`               | Pulled JSON + generated tables        |
| `experiment/backends/{android,ios}/`         | Backend implementations               |
| `experiment/{storage,backends}/ios/Tests/`   | Simulator-runnable XCTest data-path tests |

The path `~/Proyectos/dazzle` is the author's working tree. All
commands below are relative to the repo root.

## 2) Rebuild storage tables (§5.2, §5.3, §5.5, §5.6)

### Android (Moto G35 5G)

```bash
# Storage-only sweep across all 11 storage backends (Table 3, Table 5):
research/scripts/run_full_benchmark.sh --storage-only --count 10

# N-scaling sweep (Table 5b is the iOS counterpart):
research/scripts/run_full_benchmark.sh --scale --count 3 \
    --backends sqlite,sqlite-optimized,sqlite-precompute,dazzle-precompute,inmemory,lmdb \
    --scale-counts 200,1000,5000,20000

# SQLite-family microbench (paper §5.2 fairness mitigation):
research/scripts/run_storage_microbench_per_backend.sh \
    --backends sqlite,sqlite-optimized,sqlite-precompute
```

### iOS (iPhone 12 Pro, physical device)

```bash
# Build + install + sweep (auto-detects connected iPhone via xcrun devicectl):
research/scripts/run_ios_benchmark.sh --storage-only --count 3 \
    --dataset dataset_iot_baseline

# Specific backend (e.g. the new SQLite-Precompute or ObjectBox iOS port):
research/scripts/run_ios_benchmark.sh --storage-only --count 3 \
    --backends sqlite-precompute,objectbox

# N-scaling on iPhone:
research/scripts/run_ios_benchmark.sh --scale --count 3 \
    --backends sqlite-precompute,inmemory \
    --scale-counts 200,1000,5000,20000
```

### Aggregate

```bash
research/scripts/analyze_results.py
research/scripts/analyze_storage_microbench.py
research/scripts/analyze_sqlite_family_storage.py
```

## 3) Rebuild vector benchmark (§5.8 — Tables 11, 12, 13, 14)

The two devices share the same paper-grade preset:

| Platform | App / Bundle ID                           | Preset key                   |
|----------|-------------------------------------------|------------------------------|
| Android  | `dev.dazzle.experiment` (LLM app)         | `vector-bench-paper384-scale` (one-shot, dim=384, N∈{200,1k,5k,20k}) |
| iOS      | `io.dazzle.experiment.backends`           | `VECTOR_CONFIGS=paper384_scale` (same grid) |

```bash
# Android (one-shot, mirrors iOS preset 1:1):
research/scripts/run_full_benchmark.sh --vector-bench --backends vector-bench-paper384-scale

# iOS (env-var driven launch via devicectl):
xcrun devicectl device process launch \
    --device <iPhone_id> --terminate-existing \
    --environment-variables '{"VECTOR_BENCH":"true","VECTOR_CONFIGS":"paper384_scale"}' \
    io.dazzle.experiment.backends

# Optional: SQLite-family-only variant sweep (Tables 12-14 background):
research/scripts/run_vector_sqlite_family.sh
research/scripts/run_vector_sqlite_family_sweep.sh
```

Aggregate to paper-shape tables:

```bash
research/scripts/make_vector_bench_table.py
research/scripts/analyze_vector_sqlite_family.py
research/scripts/analyze_vector_sqlite_family_sweep.py
```

Expected JSON output: `vecbench_<MODEL>_<ts>.json` in
`research/benchmarks/results/<device>/vector/`. Per-engine
`db_file_bytes` is populated for SQLite-family + Dazzle rows; the
Dazzle value comes from `INFO memory → used_memory_dataset` (see
the Table 11 footnote in the paper for what that does and does not
cover).

## 4) Rebuild end-to-end RAG metrics (§5.9)

```bash
# Regenerate the deterministic NQ-open mini-slice (sha256 prefix
# 63be4b8894c71ff3 must match research/data/nq_slice/ checksum):
python3 research/scripts/nq_slice.py

# Recompute the SQuAD v1.1-normalised short-answer metrics from the
# stored RAG generations (corrects the v1 EM_short / F1_short bug
# documented in §5.9.2 Erratum):
python3 research/scripts/recompute_rag_metrics.py
```

The 200-query slice is filtered to questions with at least one
`short_answers` alias before sampling — see the alias-precondition
note in §5.9.1.

## 5) Pre-device validation (XCTest data-path tests)

Run on the iOS simulator before flashing the device. These are not
performance tests — they catch null/typo/SQL-bind regressions in
seconds so the device run only measures latency, not bug surface.

```bash
# Storage backends (SqlitePrecompute, ObjectBox iOS):
xcodebuild -project experiment/storage/ios/DazzleStorage.xcodeproj \
    -scheme DazzleStorageTests \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# SQLiteAI vector data path (svai_open → bundled sqlite3 →
# sqlite3_load_extension → vector.framework round-trip):
xcodebuild -project experiment/backends/ios/DazzleBackends.xcodeproj \
    -scheme DazzleBackendsTests \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## 6) Build the PDF

The build uses **tectonic** (single-binary Rust LaTeX engine), not
xelatex. A small `sed` pre-processor strips numeric prefixes from
markdown headings before pandoc emits LaTeX, because `arxiv.sty`
auto-numbers sections and we'd otherwise get "5.2 5.2 …" double-
numbering.

```bash
cd research/paper

sed -E 's/^(#+)[[:space:]]+([0-9]+\.[0-9]+\.?|[0-9]+\.|A\.[0-9]+\.?)[[:space:]]+/\1 /' paper_v2_en.md \
  | pandoc -f markdown -t latex --columns=80 --syntax-highlighting=none \
           -o arxiv-build/body.tex

cd arxiv-build
PATH="/Library/TeX/texbin:$PATH" tectonic paper.tex
```

Final artifact: `research/paper/arxiv-build/paper.pdf`.

`paper.aux`, `paper.bbl`, `paper.blg`, `paper.log`, `paper.out` are
gitignored — they regenerate cleanly from `tectonic paper.tex` and
shouldn't be tracked.

## 7) Vendored binary dependencies (not in git)

| What                          | Where to fetch                                                                  |
|-------------------------------|---------------------------------------------------------------------------------|
| RocksDB iOS xcframework       | `experiment/backends/ios/rocksdb/build_rocksdb_ios.sh`                          |
| SQLiteAI vector.xcframework   | `experiment/backends/ios/sqlitevectorai/download_xcframework.sh`                |
| ObjectBox iOS framework + Sourcery codegen | `experiment/backends/ios/objectbox/download_objectbox.sh`         |

All three are gitignored and required for a fresh-checkout build of
the iOS bench targets.

## 8) Notes

- Measurements are hardware-dependent (device model, OS version,
  thermal state). The paper reports physical-device numbers only
  (Moto G35 5G + iPhone 12 Pro); simulator runs are used for
  XCTest data-path validation, never for paper tables (see
  `~/.claude/projects/.../memory/feedback_paper_devices.md`).
- Default-config backend comparisons in §5.2 are intentionally
  reported as default baselines; tuned variants are discussed in
  §6.3 limitations.
- The Erratum in §5.9.2 references commit `f999003` (internal git
  history only — no external preprint published with the broken
  metrics). Reviewers seeing the v1 of that section should discard
  its `EM_short` / `F1_short` figures and use the corrected
  numbers reported in Table 15.
