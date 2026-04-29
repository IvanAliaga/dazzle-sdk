#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# SPDX-License-Identifier: Apache-2.0
"""
Summariser for the dazzle-vector / sqlite / sqlite-vec / ObjectBox-vector
benchmark JSON produced by [VectorBenchmark.kt].

Each config in the JSON contains four backend blocks:

  sqlite      — stock Android SQLite, brute-force linear scan in Kotlin
                (also used as recall ground truth for every other backend)
  sqlite_vec  — sqlite-vec 0.1.9 vec0 virtual table (brute-force in C)
  objectbox   — ObjectBox 5.x on-device HNSW
  dazzle_hnsw — dazzle-vector / valkey-search HNSW, swept across ef_runtime

For every (dim, N) we print one row per backend plus one row per ef for
dazzle, with search p50/p95, recall@k, and speedup vs stock SQLite's p50.

Usage:
    python3 vector_bench_ground_truth.py vecbench_*.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def fmt_lat(block: dict, key: str = "search_lat_us") -> tuple[int, int]:
    lat = block.get(key, {})
    return lat.get("p50", 0), lat.get("p95", 0)


def summarise(json_path: Path) -> None:
    data = json.loads(json_path.read_text())
    dev = data.get("device", {})
    print(f"# {json_path.name}")
    print(f"# device: {dev.get('model', '?')} (abi={dev.get('abi', '?')})")
    print(f"# timestamp: {data.get('timestamp', '?')}")
    print(f"# baseline: dazzle-hnsw @ highest-recall ef per config; "
          f"speedup = dazzle_p50 / backend_p50 (>1 means faster than dazzle)")
    print()
    header = (f"{'dim':>5} {'N':>7} {'backend':>12} {'param':>8} "
              f"{'recall@k':>9} {'p50µs':>8} {'p95µs':>8} "
              f"{'ingest_ms':>10} {'vs_dazzle':>10}")
    print(header)
    print("-" * len(header))
    for cfg in data.get("configs", []):
        if "error" in cfg:
            print(f"{cfg.get('dim','?'):>5} {cfg.get('n_docs','?'):>7}  "
                  f"ERROR: {cfg['error']}")
            continue
        dim = cfg["dim"]
        n   = cfg["n_docs"]

        # ── pick dazzle reference: the ef row with highest recall,
        #    breaking ties toward lowest p50 (the realistic operating point).
        dz = cfg.get("dazzle_hnsw", {})
        dz_ing = dz.get("ingest_total_ms", 0)
        dz_rows = dz.get("by_ef", [])
        def dz_key(r: dict) -> tuple:
            lat = r.get("search_lat_us", {})
            return (-r.get("recall_at_k", 0.0), lat.get("p50", 10**12))
        dz_ref = min(dz_rows, key=dz_key) if dz_rows else None
        dz_p50 = dz_ref["search_lat_us"]["p50"] if dz_ref else 0

        def row(label: str, param: str, recall: float, p50: int, p95: int,
                ingest_ms: int, is_dazzle_ref: bool = False) -> None:
            if dz_p50 <= 0 or p50 <= 0:
                ratio = "—"
            elif is_dazzle_ref:
                ratio = "1.0x (ref)"
            else:
                ratio = f"{dz_p50 / p50:.1f}x"
            print(f"{dim:>5} {n:>7} {label:>12} {param:>8} "
                  f"{recall:>9.4f} {p50:>8} {p95:>8} "
                  f"{ingest_ms:>10} {ratio:>10}")

        # dazzle reference row first so the eye anchors on it.
        if dz_ref is not None:
            lat = dz_ref["search_lat_us"]
            row("dazzle-hnsw", f"ef={dz_ref['ef_runtime']}",
                dz_ref.get("recall_at_k", 0.0),
                lat.get("p50", 0), lat.get("p95", 0), dz_ing,
                is_dazzle_ref=True)

        # stock SQLite brute-force is only kept for recall ground truth;
        # omit it from the headline table — it's not a serious competitor.

        if "sqlite_vec" in cfg:
            sv = cfg["sqlite_vec"]
            sv_p50, sv_p95 = fmt_lat(sv)
            row("sqlite-vec", "-", sv.get("recall_at_k", 0.0),
                sv_p50, sv_p95, sv.get("ingest_total_ms", 0))

        if "objectbox" in cfg:
            ob = cfg["objectbox"]
            ob_p50, ob_p95 = fmt_lat(ob)
            row("objectbox", "-", ob.get("recall_at_k", 0.0),
                ob_p50, ob_p95, ob.get("ingest_total_ms", 0))

        # Remaining dazzle ef points (other operating knobs).
        for r in dz_rows:
            if r is dz_ref:
                continue
            lat = r.get("search_lat_us", {})
            row("dazzle-hnsw", f"ef={r.get('ef_runtime', 0)}",
                r.get("recall_at_k", 0.0),
                lat.get("p50", 0), lat.get("p95", 0), dz_ing)
        print()


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("json", type=Path, nargs="+")
    args = p.parse_args()
    for jp in args.json:
        if not jp.exists():
            print(f"missing: {jp}", file=sys.stderr)
            continue
        summarise(jp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
