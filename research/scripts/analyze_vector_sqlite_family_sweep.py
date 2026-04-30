#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# SPDX-License-Identifier: Apache-2.0

"""
Aggregate vecbench_sqlite_family_sweep_*.json runs into paper-ready tables.

Usage:
  python3 research/scripts/analyze_vector_sqlite_family_sweep.py <run_dir_or_json>
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from pathlib import Path

VARIANT_ORDER = [
    "sqlite_plain",
    "sqlite_vec_default",
    "sqlite_vec_optimized",
    "sqlite_vec_precompute",
    "sqlite_vector_ai_default",
    "sqlite_vector_ai_optimized",
    "sqlite_vector_ai_precompute",
]

DISPLAY = {
    "sqlite_plain": "SQLite plain",
    "sqlite_vec_default": "sqlite-vec default",
    "sqlite_vec_optimized": "sqlite-vec optimized",
    "sqlite_vec_precompute": "sqlite-vec precompute",
    "sqlite_vector_ai_default": "SQLiteAI default",
    "sqlite_vector_ai_optimized": "SQLiteAI optimized",
    "sqlite_vector_ai_precompute": "SQLiteAI precompute",
}


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def stdev(xs: list[float]) -> float:
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def fmt(x: float, digits: int = 2) -> str:
    return f"{x:.{digits}f}"


def mb(x: float) -> float:
    return x / (1024.0 * 1024.0)


def collect_jsons(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(path.rglob("vecbench_sqlite_family_sweep_*.json"))


def load(path: Path):
    by_n_variant: dict[int, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    device = "unknown device"
    for p in collect_jsons(path):
        data = json.loads(p.read_text())
        if data.get("type") != "vector_sqlite_family_sweep_benchmark":
            continue
        dev = data.get("device", {}) or {}
        device = dev.get("model") or device
        for cfg in data.get("configs", []):
            c = cfg.get("config", {}) or {}
            n = int(c.get("n_docs", 0))
            res = cfg.get("results", {}) or {}
            for k, v in res.items():
                if isinstance(v, dict):
                    by_n_variant[n][k].append(v)
    return by_n_variant, device


def render_nsweep(by_n_variant: dict[int, dict[str, list[dict]]], device: str, source: Path) -> str:
    ns = sorted(by_n_variant.keys())
    out = [
        f"# Vector SQLite Family N-Sweep — {device}",
        "",
        f"Source: `{source}`",
        "",
        "| Variant | " + " | ".join([f"N={n} p50 (µs)" for n in ns]) + " |",
        "|---|" + "|".join(["---:" for _ in ns]) + "|",
    ]
    for v in VARIANT_ORDER:
        row = [DISPLAY.get(v, v)]
        for n in ns:
            rs = by_n_variant.get(n, {}).get(v, [])
            p50s = [float((r.get("search_lat_us", {}) or {}).get("p50", 0.0)) for r in rs]
            if p50s:
                row.append(f"{fmt(mean(p50s), 2)} ± {fmt(stdev(p50s), 2)}")
            else:
                row.append("—")
        out.append("| " + " | ".join(row) + " |")
    out += ["", ""]
    return "\n".join(out)


def render_footprint(by_n_variant: dict[int, dict[str, list[dict]]], device: str, source: Path) -> str:
    ns = sorted(by_n_variant.keys())
    out = [
        f"# Vector SQLite Family Footprint — {device}",
        "",
        f"Source: `{source}`",
        "",
        "| Variant | " + " | ".join([f"N={n} DB size (MB)" for n in ns]) + " |",
        "|---|" + "|".join(["---:" for _ in ns]) + "|",
    ]
    for v in VARIANT_ORDER:
        row = [DISPLAY.get(v, v)]
        for n in ns:
            rs = by_n_variant.get(n, {}).get(v, [])
            bs = [float(r.get("db_file_bytes", -1)) for r in rs if float(r.get("db_file_bytes", -1)) >= 0]
            if bs:
                row.append(f"{fmt(mb(mean(bs)), 3)}")
            else:
                row.append("—")
        out.append("| " + " | ".join(row) + " |")
    out += ["", ""]
    return "\n".join(out)


def render_ingest_nsweep(by_n_variant: dict[int, dict[str, list[dict]]], device: str, source: Path) -> str:
    ns = sorted(by_n_variant.keys())
    out = [
        f"# Vector SQLite Family Ingest N-Sweep — {device}",
        "",
        f"Source: `{source}`",
        "",
        "| Variant | " + " | ".join([f"N={n} ingest total (ms)" for n in ns]) + " |",
        "|---|" + "|".join(["---:" for _ in ns]) + "|",
    ]
    for v in VARIANT_ORDER:
        row = [DISPLAY.get(v, v)]
        for n in ns:
            rs = by_n_variant.get(n, {}).get(v, [])
            ingest = [float(r.get("ingest_total_ms", 0.0)) for r in rs]
            if ingest:
                row.append(f"{fmt(mean(ingest), 2)} ± {fmt(stdev(ingest), 2)}")
            else:
                row.append("—")
        out.append("| " + " | ".join(row) + " |")
    out += ["", ""]
    return "\n".join(out)


def render_ops_10k(by_n_variant: dict[int, dict[str, list[dict]]], device: str, source: Path) -> str:
    n = 10_000
    by_variant = by_n_variant.get(n, {})
    out = [
        f"# Vector SQLite Family Operating Point (dim=384, N=10,000) — {device}",
        "",
        f"Source: `{source}`",
        "",
        "| Variant | Algorithm | Recall@10 | p50 search (µs) | Ingest total (ms) | DB size (MB) |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for v in VARIANT_ORDER:
        rs = by_variant.get(v, [])
        if not rs:
            out.append(f"| {DISPLAY.get(v, v)} | — | — | — | — | — |")
            continue
        algo = str(rs[0].get("algorithm_class", "—"))
        recalls = [float(r.get("recall_at_k", 0.0)) for r in rs]
        p50s = [float((r.get("search_lat_us", {}) or {}).get("p50", 0.0)) for r in rs]
        ingest = [float(r.get("ingest_total_ms", 0.0)) for r in rs]
        bs = [float(r.get("db_file_bytes", -1)) for r in rs if float(r.get("db_file_bytes", -1)) >= 0]
        size_cell = f"{fmt(mb(mean(bs)), 3)}" if bs else "—"
        out.append(
            f"| {DISPLAY.get(v, v)} | {algo} | {fmt(mean(recalls), 3)} | "
            f"{fmt(mean(p50s), 2)} ± {fmt(stdev(p50s), 2)} | "
            f"{fmt(mean(ingest), 2)} | {size_cell} |"
        )
    out += ["", ""]
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: python3 research/scripts/analyze_vector_sqlite_family_sweep.py <run_dir_or_json>",
            file=sys.stderr,
        )
        return 2
    src = Path(sys.argv[1]).resolve()
    if not src.exists():
        print(f"Path not found: {src}", file=sys.stderr)
        return 2

    by_n_variant, device = load(src)
    if not by_n_variant:
        print(f"No vector_sqlite_family_sweep_benchmark data in {src}", file=sys.stderr)
        return 1

    out_dir = src.parent if src.is_file() else src
    md_ns = render_nsweep(by_n_variant, device, src)
    md_fp = render_footprint(by_n_variant, device, src)
    md_ing = render_ingest_nsweep(by_n_variant, device, src)
    md_op = render_ops_10k(by_n_variant, device, src)

    p1 = out_dir / "table_vector_sqlite_family_nsweep.md"
    p2 = out_dir / "table_vector_sqlite_family_footprint.md"
    p3 = out_dir / "table_vector_sqlite_family_ingest_nsweep.md"
    p4 = out_dir / "table_vector_sqlite_family_ops_10k.md"
    p1.write_text(md_ns + "\n")
    p2.write_text(md_fp + "\n")
    p3.write_text(md_ing + "\n")
    p4.write_text(md_op + "\n")
    print(f"wrote {p1}")
    print(f"wrote {p2}")
    print(f"wrote {p3}")
    print(f"wrote {p4}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
