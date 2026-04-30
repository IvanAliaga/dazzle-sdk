#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# SPDX-License-Identifier: Apache-2.0

"""
Build focused SQLite-family storage tables from scale_benchmark JSON files.

Targets:
  - sqlite
  - sqlite-optimized
  - sqlite-precompute

Usage:
  python3 research/scripts/analyze_sqlite_family_storage.py <device_results_dir>
"""

from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from pathlib import Path

TARGETS = ["sqlite", "sqlite-optimized", "sqlite-precompute"]


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


def collect_scale_jsons(root: Path) -> list[Path]:
    out = []
    for p in root.rglob("scale_*.json"):
        if any(f"/{t}/" in str(p) for t in TARGETS):
            out.append(p)
    return sorted(out)


def load(root: Path):
    # backend -> n -> field -> values
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for p in collect_scale_jsons(root):
        try:
            j = json.loads(p.read_text())
        except Exception:
            continue
        if j.get("type") != "scale_benchmark":
            continue
        bk = str(j.get("backend", "unknown")).lower()
        if bk not in TARGETS:
            continue
        for pt in j.get("scale_points", []):
            n = int(pt.get("n", 0))
            for key in [
                "retrieval_avg_us",
                "ingest_total_ms",
                "backend_size_after_bytes",
                "backend_size_delta_bytes",
            ]:
                v = pt.get(key)
                if v is None:
                    continue
                data[bk][n][key].append(float(v))
    return data


def render_latency_table(data) -> str:
    ns = sorted({n for bk in data for n in data[bk]})
    out = [
        "# SQLite Family N-Sweep — Latency",
        "",
        "| Backend | " + " | ".join([f"N={n} retrieval (µs)" for n in ns]) + " |",
        "|---|" + "|".join(["---:" for _ in ns]) + "|",
    ]
    for bk in TARGETS:
        row = [bk]
        for n in ns:
            vals = data.get(bk, {}).get(n, {}).get("retrieval_avg_us", [])
            if vals:
                row.append(f"{fmt(mean(vals), 1)} ± {fmt(stdev(vals), 1)}")
            else:
                row.append("—")
        out.append("| " + " | ".join(row) + " |")

    out += [
        "",
        "| Backend | " + " | ".join([f"N={n} ingest total (ms)" for n in ns]) + " |",
        "|---|" + "|".join(["---:" for _ in ns]) + "|",
    ]
    for bk in TARGETS:
        row = [bk]
        for n in ns:
            vals = data.get(bk, {}).get(n, {}).get("ingest_total_ms", [])
            if vals:
                row.append(f"{fmt(mean(vals), 2)} ± {fmt(stdev(vals), 2)}")
            else:
                row.append("—")
        out.append("| " + " | ".join(row) + " |")
    out += ["", ""]
    return "\n".join(out)


def render_footprint_table(data) -> str:
    ns = sorted({n for bk in data for n in data[bk]})
    out = [
        "# SQLite Family N-Sweep — Storage Footprint",
        "",
        "| Backend | " + " | ".join([f"N={n} DB size after ingest (MB)" for n in ns]) + " |",
        "|---|" + "|".join(["---:" for _ in ns]) + "|",
    ]
    for bk in TARGETS:
        row = [bk]
        for n in ns:
            vals = data.get(bk, {}).get(n, {}).get("backend_size_after_bytes", [])
            vals = [v for v in vals if v >= 0]
            if vals:
                row.append(f"{fmt(mb(mean(vals)), 3)}")
            else:
                row.append("—")
        out.append("| " + " | ".join(row) + " |")
    out += ["", ""]
    return "\n".join(out)


def render_n200_snapshot(data) -> str:
    n = 200
    out = [
        "# SQLite Family Snapshot at N=200 (after 200 ingests)",
        "",
        "| Backend | Retrieval avg (µs) | Ingest total (ms) | DB size after ingest (MB) |",
        "|---|---:|---:|---:|",
    ]
    for bk in TARGETS:
        d = data.get(bk, {}).get(n, {})
        r = d.get("retrieval_avg_us", [])
        i = d.get("ingest_total_ms", [])
        b = [v for v in d.get("backend_size_after_bytes", []) if v >= 0]
        out.append(
            f"| {bk} | "
            f"{(f'{fmt(mean(r), 1)} ± {fmt(stdev(r), 1)}' if r else '—')} | "
            f"{(f'{fmt(mean(i), 2)} ± {fmt(stdev(i), 2)}' if i else '—')} | "
            f"{(fmt(mb(mean(b)), 3) if b else '—')} |"
        )
    out += ["", ""]
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 research/scripts/analyze_sqlite_family_storage.py <device_results_dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    if not root.exists():
        print(f"Path not found: {root}", file=sys.stderr)
        return 2
    data = load(root)
    if not data:
        print(f"No SQLite-family scale_benchmark data under {root}", file=sys.stderr)
        return 1

    p1 = root / "table_sqlite_family_scale_latency.md"
    p2 = root / "table_sqlite_family_scale_footprint.md"
    p3 = root / "table_sqlite_family_n200_snapshot.md"
    p1.write_text(render_latency_table(data) + "\n")
    p2.write_text(render_footprint_table(data) + "\n")
    p3.write_text(render_n200_snapshot(data) + "\n")
    print(f"wrote {p1}")
    print(f"wrote {p2}")
    print(f"wrote {p3}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
