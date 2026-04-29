#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# SPDX-License-Identifier: Apache-2.0

"""
Aggregate vecbench_sqlite_family_*.json outputs into a paper-ready table.

Usage:
  python3 research/scripts/analyze_vector_sqlite_family.py <run_dir_or_json>
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from pathlib import Path


ROW_ORDER = [
    "sqlite_plain",
    "sqlite_vec_default",
    "sqlite_vec_optimized",
    "sqlite_vec_precompute",
    "sqlite_vector_ai_default",
    "sqlite_vector_ai_optimized",
    "sqlite_vector_ai_precompute",
]


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def stdev(xs: list[float]) -> float:
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def collect_jsons(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(path.rglob("vecbench_sqlite_family_*.json"))


def load_rows(paths: list[Path]) -> tuple[dict[str, list[dict]], str]:
    rows: dict[str, list[dict]] = defaultdict(list)
    device = "unknown device"
    for p in paths:
        data = json.loads(p.read_text())
        if data.get("type") != "vector_sqlite_family_benchmark":
            continue
        dev = data.get("device", {}) or {}
        device = dev.get("model") or device
        results = data.get("results", {}) or {}
        for k, v in results.items():
            if isinstance(v, dict):
                rows[k].append(v)
    return rows, device


def fmt(x: float, digits: int = 2) -> str:
    return f"{x:.{digits}f}"


def render(rows: dict[str, list[dict]], device: str, source: Path) -> str:
    out = [
        f"# Vector SQLite Family — {device}",
        "",
        f"Source: `{source}`",
        "",
        "| Backend Variant | n | Algorithm | Recall@10 | p50 search (µs) | p95 search (µs) | Ingest total (ms) |",
        "|---|---:|---|---:|---:|---:|---:|",
    ]

    for key in ROW_ORDER:
        rs = rows.get(key, [])
        if not rs:
            continue
        algo = str(rs[0].get("algorithm_class", "—"))
        recall = [float(r.get("recall_at_k", 0.0)) for r in rs]
        p50 = [float((r.get("search_lat_us", {}) or {}).get("p50", 0.0)) for r in rs]
        p95 = [float((r.get("search_lat_us", {}) or {}).get("p95", 0.0)) for r in rs]
        ing = [float(r.get("ingest_total_ms", 0.0)) for r in rs]
        out.append(
            f"| {key} | {len(rs)} | {algo} | "
            f"{fmt(mean(recall), 3)} | "
            f"{fmt(mean(p50), 2)} ± {fmt(stdev(p50), 2)} | "
            f"{fmt(mean(p95), 2)} | "
            f"{fmt(mean(ing), 2)} |"
        )

    out += [
        "",
        "## Interpretation Notes",
        "",
        "- `sqlite_vec_precompute` = pre-normalized vectors + extended warm cache; sqlite-vec remains linear scan.",
        "- `sqlite_vector_ai_precompute` = quantize + preload path (`vector_quantize_preload`).",
        "- Compare by algorithm class first; then compare constants within class.",
        "",
    ]
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: python3 research/scripts/analyze_vector_sqlite_family.py <run_dir_or_json>",
            file=sys.stderr,
        )
        return 2

    src = Path(sys.argv[1]).resolve()
    if not src.exists():
        print(f"Path not found: {src}", file=sys.stderr)
        return 2

    jsons = collect_jsons(src)
    if not jsons:
        print(f"No vecbench_sqlite_family_*.json found under {src}", file=sys.stderr)
        return 1

    rows, device = load_rows(jsons)
    if not rows:
        print(f"No valid vector_sqlite_family_benchmark JSON in {src}", file=sys.stderr)
        return 1

    md = render(rows, device, src)
    out_path = src.parent / "table_vector_sqlite_family.md" if src.is_file() else src / "table_vector_sqlite_family.md"
    out_path.write_text(md + "\n")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
