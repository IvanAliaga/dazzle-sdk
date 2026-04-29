#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
analyze_storage_microbench.py

Analyze one isolated microbenchmark run directory (timestamped run id)
and generate clean per-device markdown tables without historical mixing.

Expected input layout:
  <run_dir>/<device>/<backend>/storageonly_<backend>_*.json

Usage:
  python3 research/scripts/analyze_storage_microbench.py \
      research/benchmarks/results/microbench/20260427-123000
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from pathlib import Path

EXPECTED_BACKEND_LABELS = {
    "dazzle": "Dazzle",
    "dazzle-pipeline": "Dazzle-Pipeline",
    "dazzle-precompute": "Dazzle-Precompute",
    "dazzle-lua": "Dazzle-Lua",
    "dazzle-hfe": "Dazzle-HFE",
    "dazzle-hll": "Dazzle-HLL",
    "dazzle-vector": "Dazzle-Vector",
    "valkey": "Valkey",
    "sqlite": "SQLite",
    "sqlite-optimized": "SQLite-Optimized",
    "sqlite-precompute": "SQLite-Precompute",
    "lmdb": "LMDB",
    "rocksdb": "RocksDB",
    "inmemory": "InMemory",
    "objectbox": "ObjectBox",
}


def mean(vals: list[float]) -> float:
    return sum(vals) / len(vals) if vals else 0.0


def stdev(vals: list[float]) -> float:
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def stderr(vals: list[float]) -> float:
    if len(vals) < 2:
        return 0.0
    return stdev(vals) / math.sqrt(len(vals))


def load_storage_jsons(run_dir: Path) -> tuple[dict[str, dict[str, list[dict]]], list[tuple[str, str, str, str]]]:
    out: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    rejected: list[tuple[str, str, str, str]] = []
    for p in sorted(run_dir.rglob("storageonly_*.json")):
        try:
            data = json.loads(p.read_text())
        except Exception:
            continue
        if data.get("type") != "storage_only":
            continue
        rel = p.relative_to(run_dir).parts
        # run_dir/device/backend/file.json
        if len(rel) < 3:
            continue
        device = rel[0]
        backend = rel[1]
        expected = EXPECTED_BACKEND_LABELS.get(backend)
        actual = str(data.get("backend", ""))
        if expected and actual and actual != expected:
            rejected.append((str(p), backend, actual, expected))
            continue
        out[device][backend].append(data)
    return out, rejected


def backend_sort_key(name: str) -> tuple[int, str]:
    order = [
        "dazzle-precompute",
        "sqlite",
        "sqlite-optimized",
        "sqlite-precompute",
        "inmemory",
        "objectbox",
        "lmdb",
        "rocksdb",
    ]
    try:
        return (order.index(name), name)
    except ValueError:
        return (999, name)


def render_device_table(device: str, by_backend: dict[str, list[dict]], run_dir: Path) -> Path:
    lines = [
        f"# Storage Microbench — {device}",
        "",
        f"Run root: `{run_dir}`",
        "",
        "| Backend | n | Retrieval avg (µs) | P50 (µs) | P95 (µs) | Ingest (ms) | Per-ingest (µs) | Tokens(ctx) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for backend in sorted(by_backend.keys(), key=backend_sort_key):
        runs = by_backend[backend]
        avg_ret = [float(r.get("avg_retrieval_us", 0.0)) for r in runs]
        p50 = [float(r.get("p50_retrieval_us", 0.0)) for r in runs]
        p95 = [float(r.get("p95_retrieval_us", 0.0)) for r in runs]
        ingest = [float(r.get("ingest_total_ms", 0.0)) for r in runs]
        per_ing = [float(r.get("per_ingest_us", 0.0)) for r in runs]
        tok = [float(r.get("context_tokens_est", 0.0)) for r in runs]
        display = runs[0].get("backend", backend)
        lines.append(
            f"| {display} | {len(runs)} | "
            f"{mean(avg_ret):.3f} ± {stdev(avg_ret):.3f} | "
            f"{mean(p50):.3f} | {mean(p95):.3f} | "
            f"{mean(ingest):.3f} | {mean(per_ing):.3f} | {mean(tok):.1f} |"
        )
    lines += ["", "## Pairwise Focus (SQLite Family)", ""]

    if "sqlite" in by_backend and "sqlite-optimized" in by_backend:
        s = [float(r.get("avg_retrieval_us", 0.0)) for r in by_backend["sqlite"]]
        so = [float(r.get("avg_retrieval_us", 0.0)) for r in by_backend["sqlite-optimized"]]
        d = mean(so) - mean(s)
        rel = (mean(so) / mean(s) - 1.0) * 100.0 if mean(s) > 0 else 0.0
        lines.append(
            f"- Retrieval delta (optimized - default): `{d:+.3f} µs` "
            f"(`{rel:+.2f}%`, n={len(s)} vs n={len(so)})."
        )
        lines.append(
            f"- 95% CI approx: default `±{1.96*stderr(s):.3f} µs`, "
            f"optimized `±{1.96*stderr(so):.3f} µs`."
        )
    else:
        lines.append("- Missing one of SQLite / SQLite-Optimized in this run.")

    if "sqlite" in by_backend and "sqlite-precompute" in by_backend:
        s = [float(r.get("avg_retrieval_us", 0.0)) for r in by_backend["sqlite"]]
        sp = [float(r.get("avg_retrieval_us", 0.0)) for r in by_backend["sqlite-precompute"]]
        d = mean(sp) - mean(s)
        rel = (mean(sp) / mean(s) - 1.0) * 100.0 if mean(s) > 0 else 0.0
        lines.append(
            f"- Retrieval delta (precompute - default): `{d:+.3f} µs` "
            f"(`{rel:+.2f}%`, n={len(s)} vs n={len(sp)})."
        )
        lines.append(
            f"- 95% CI approx: default `±{1.96*stderr(s):.3f} µs`, "
            f"precompute `±{1.96*stderr(sp):.3f} µs`."
        )

    out = run_dir / device / "table_storage_microbench.md"
    out.write_text("\n".join(lines) + "\n")
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: python3 research/scripts/analyze_storage_microbench.py "
            "<run_dir>",
            file=sys.stderr,
        )
        return 2

    run_dir = Path(sys.argv[1]).resolve()
    if not run_dir.exists():
        print(f"Run dir not found: {run_dir}", file=sys.stderr)
        return 2

    data, rejected = load_storage_jsons(run_dir)
    if not data:
        print(f"No storageonly JSONs found under {run_dir}")
        return 1

    if rejected:
        print(f"Skipped {len(rejected)} JSONs with backend-label mismatch:", file=sys.stderr)
        for p, key, actual, expected in rejected[:10]:
            print(
                f"  - {p}: key='{key}' backend='{actual}' expected='{expected}'",
                file=sys.stderr,
            )
        if len(rejected) > 10:
            print(f"  ... and {len(rejected) - 10} more", file=sys.stderr)

    print(f"Loaded microbench run: {run_dir}")
    for device, by_backend in sorted(data.items()):
        out = render_device_table(device, by_backend, run_dir)
        total = sum(len(v) for v in by_backend.values())
        print(f"  {device}: {total} runs across {len(by_backend)} backends -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
