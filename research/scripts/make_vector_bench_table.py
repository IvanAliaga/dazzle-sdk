#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Build paper-ready vector benchmark tables separated by algorithm class:
#   - Table Xa: HNSW-class engines (O(log N))
#   - Table Xb: Linear-scan engines (O(N))
#
# Usage:
#   research/scripts/make_vector_bench_table.py path/to/vecbench_*.json
#   research/scripts/make_vector_bench_table.py path/to/vecbench_*.json --out path/to/table_vector_bench.md

import argparse
import json
from pathlib import Path


HNSW_ROWS = [
    ("dazzle_sq8", "Dazzle SQ8", "HNSW", "int8"),
    ("dazzle_hnsw", "Dazzle HNSW", "HNSW", "float32"),
    ("objectbox", "ObjectBox 4.x", "HNSW", "float32"),
]

LINEAR_ROWS = [
    ("sqlite_vector_ai", "SQLiteAI 0.9.95", "quantized scan", "int8"),
    ("sqlite_vec", "sqlite-vec", "brute-force scan", "float32"),
    ("sqlite", "SQLite (plain)", "brute-force scan", "float32"),
]


def choose_cfg(configs, dim=384, target_n=10_000):
    cands = [c for c in configs if c.get("dim") == dim and "error" not in c]
    if not cands:
        return None
    for c in cands:
        if c.get("n_docs") == target_n:
            return c
    # fallback: pick highest N for the same dim
    return sorted(cands, key=lambda c: c.get("n_docs", 0))[-1]


def pick_ef_row(entry, ef_runtime=10):
    if not entry or not isinstance(entry, dict) or entry.get("skipped"):
        return None
    rows = entry.get("by_ef") or []
    for r in rows:
        if r.get("ef_runtime") == ef_runtime:
            return r
    return rows[0] if rows else None


def metrics(cfg, key, ef_runtime=10):
    entry = cfg.get(key)
    if not entry or not isinstance(entry, dict) or entry.get("skipped"):
        return None
    if "by_ef" in entry:
        row = pick_ef_row(entry, ef_runtime=ef_runtime)
        if row is None:
            return None
        return {
            "p50": row.get("search_lat_us", {}).get("p50"),
            "recall": row.get("recall_at_k"),
            "ingest": entry.get("ingest_total_ms"),
            "ef": row.get("ef_runtime"),
        }
    return {
        "p50": entry.get("search_lat_us", {}).get("p50"),
        "recall": entry.get("recall_at_k"),
        "ingest": entry.get("ingest_total_ms"),
        "ef": None,
    }


def fmt_num(x, digits=1):
    if x is None:
        return "—"
    if isinstance(x, float):
        return f"{x:.{digits}f}"
    return str(x)


def render_table(title, rows, cfg):
    out = [title, ""]
    out.append("| Engine | Algorithm Class | Precision | Recall@10 | p50 search (µs) | Ingest (ms) |")
    out.append("|---|---|---:|---:|---:|---:|")
    for key, name, cls, prec in rows:
        m = metrics(cfg, key)
        if m is None:
            out.append(f"| {name} | {cls} | {prec} | — | — | — |")
            continue
        out.append(
            f"| {name} | {cls} | {prec} | "
            f"{fmt_num(m['recall'], 3)} | {fmt_num(m['p50'], 1)} | {fmt_num(m['ingest'], 1)} |"
        )
    out.append("")
    return out


def render(data, device_label):
    cfg = choose_cfg(data.get("configs", []), dim=384, target_n=10_000)
    if cfg is None:
        return "\n".join([
            f"# Vector Search Benchmark — {device_label}",
            "",
            "No dim=384 config found in input JSON.",
            "",
        ])

    dim = cfg.get("dim")
    n_docs = cfg.get("n_docs")
    n_queries = cfg.get("n_queries")

    out = [
        f"# Vector Search Primitive: Envelope and Operating Points — {device_label}",
        "",
        f"Config used: dim={dim}, N={n_docs:,}, queries={n_queries:,}",
        "",
        "The benchmark is reported by algorithmic class to avoid apples-to-oranges",
        "interpretation between HNSW (O(log N)) and linear-scan (O(N)) paths.",
        "",
    ]

    out += render_table("## Table Xa — HNSW-class engines (O(log N))", HNSW_ROWS, cfg)
    out += render_table("## Table Xb — Linear-scan engines (O(N))", LINEAR_ROWS, cfg)

    out += [
        "### Notes",
        "",
        "- SQLiteAI 0.9.95 is included as a production SQLite-ecosystem reference;",
        "  its optimized path is quantized linear scan in this release.",
        "- If/when SQLite vector extensions expose HNSW in production, the primary",
        "  comparison should move to Table Xa (constant-factor analysis within class).",
        "",
    ]
    return "\n".join(out)


def device_name(data):
    dev = data.get("device", {}) or {}
    apple_model_names = {
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,2": "iPhone 12",
        "iPhone14,5": "iPhone 13",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
    }
    hw = dev.get("hw_model", "")
    return (
        apple_model_names.get(hw)
        or dev.get("model")
        or hw
        or dev.get("name")
        or "unknown device"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_path", type=Path, help="Path to vecbench_*.json")
    ap.add_argument("--out", type=Path, help="Output path (default: alongside input)")
    ap.add_argument("--device", type=str, default=None, help="Override device label")
    args = ap.parse_args()

    data = json.loads(args.json_path.read_text())
    label = args.device or device_name(data)
    md = render(data, label)

    out_path = args.out or (args.json_path.parent / "table_vector_bench.md")
    out_path.write_text(md)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
