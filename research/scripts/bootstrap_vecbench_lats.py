#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Non-parametric bootstrap (percentile method) over the per-query
search-latency arrays emitted by the patched VectorBenchmark
(`latencies_us` field added in this revision). Computes 95 % CIs on
the **p50** statistic — which is what Table 11 of the paper reports —
plus side CIs for the mean and p95 for completeness.

For Tabla 11's headline cells (Dazzle SQ8 / ObjectBox / SQLiteAI
precompute at N = 20 000, dim = 384, k = 10) the script also
bootstraps **paired** ratios when the per-query arrays share a query
order (the harness draws the same 100-query set against every engine
in the same iteration, so paired bootstrap is well-defined and
correct).

Determinism: seed = 42, B = 10 000. Same input → same output.

Usage:
    python3 research/scripts/bootstrap_vecbench_lats.py PATH_TO_VECBENCH.json
    python3 research/scripts/bootstrap_vecbench_lats.py PATH/json --B 5000 --seed 7

If multiple JSONs are passed (e.g. one per device), the script runs
the bootstrap on each independently and emits one section per device.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent.parent
OUT_PATH = REPO / "research" / "paper" / "vecbench_with_ci.md"

ENGINES = [
    "dazzle_hnsw",
    "dazzle_sq8",
    "dazzle_sq8_rerank",
    "dazzle_f16",
    "objectbox",
    "sqlite_vector_ai",
    "sqlite_vec",
    "sqlite",
]
HEADLINE_ENGINES = ("dazzle_sq8", "objectbox", "sqlite_vector_ai")  # paper headline cells


def _bootstrap_quantile(arr: np.ndarray, q: float, B: int, rng: np.random.Generator
                        ) -> tuple[float, float, float]:
    """Percentile-method bootstrap of the q-quantile."""
    n = len(arr)
    if n == 0:
        return (math.nan, math.nan, math.nan)
    idx = rng.integers(0, n, size=(B, n))
    samples = arr[idx]
    qs = np.quantile(samples, q, axis=1)
    return float(np.quantile(arr, q)), float(np.percentile(qs, 2.5)), float(np.percentile(qs, 97.5))


def _bootstrap_mean(arr: np.ndarray, B: int, rng: np.random.Generator
                    ) -> tuple[float, float, float]:
    n = len(arr)
    if n == 0:
        return (math.nan, math.nan, math.nan)
    idx = rng.integers(0, n, size=(B, n))
    means = arr[idx].mean(axis=1)
    return float(arr.mean()), float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5))


def _bootstrap_paired_ratio(num: np.ndarray, den: np.ndarray, B: int,
                             rng: np.random.Generator
                             ) -> tuple[float, float, float, bool]:
    """Paired bootstrap of median(num)/median(den). Returns
    (point, lo, hi, crosses_one)."""
    n = min(len(num), len(den))
    num = num[:n]; den = den[:n]
    if n == 0:
        return (math.nan, math.nan, math.nan, True)
    idx = rng.integers(0, n, size=(B, n))
    nm = np.median(num[idx], axis=1)
    dm = np.median(den[idx], axis=1)
    valid = dm > 0
    if valid.sum() == 0:
        return (math.nan, math.nan, math.nan, True)
    ratios = nm[valid] / dm[valid]
    point = float(np.median(num)) / max(float(np.median(den)), 1e-9)
    lo = float(np.percentile(ratios, 2.5))
    hi = float(np.percentile(ratios, 97.5))
    crosses = (lo < 1.0 < hi) or (lo > 1.0 > hi)
    return point, lo, hi, crosses


def _fmt_us(point: float, lo: float, hi: float) -> str:
    if math.isnan(point):
        return "—"
    if point >= 1000:
        return f"{point:.0f} [{lo:.0f}, {hi:.0f}]"
    return f"{point:.0f} [{lo:.0f}, {hi:.0f}]"


def _fmt_ratio(point: float, lo: float, hi: float, crosses: bool) -> str:
    if math.isnan(point):
        return "—"
    sig = "" if crosses else " ★"
    return f"{point:.2f}× [{lo:.2f}×, {hi:.2f}×]{sig}"


def process_json(json_path: Path, B: int, seed: int) -> list[str]:
    raw = json.loads(json_path.read_text())
    device = raw.get("device", {}).get("model") or json_path.stem
    lines: list[str] = []
    lines.append(f"## Device: `{device}` — `{json_path.name}`\n")
    try:
        rel = json_path.resolve().relative_to(REPO)
    except ValueError:
        rel = json_path
    lines.append(f"Source: `{rel}`")
    lines.append(f"SHA-256: `{hashlib.sha256(json_path.read_bytes()).hexdigest()}`\n")

    # Per-config tables
    for cfg in raw.get("configs", []):
        N = cfg.get("n_docs")
        dim = cfg.get("dim")
        k = cfg.get("k")
        n_q = cfg.get("n_queries")
        lines.append(f"### N = {N}, dim = {dim}, k = {k}, n_queries = {n_q}\n")

        # Helper: extract per-query latency array, normalising the
        # SQLite-family vs Dazzle structural difference. SQLite-family
        # engines store the array directly under `search_lat_us`;
        # Dazzle engines store it under `by_ef[i].search_lat_us` with
        # one entry per `efRuntime` swept. We use the FIRST ef entry
        # (lowest ef → recall-floor target) for the cross-platform
        # bootstrap so every engine is at the same operating point.
        def lats_for(eng: str) -> list[int]:
            ed = cfg.get(eng) or {}
            if ed.get("skipped"):
                return []
            if eng.startswith("dazzle"):
                by_ef = ed.get("by_ef") or []
                if not by_ef:
                    return []
                sl = (by_ef[0] or {}).get("search_lat_us") or {}
            else:
                sl = ed.get("search_lat_us") or {}
            arr = sl.get("latencies_us") or []
            return arr if isinstance(arr, list) else []

        # Verify the patched harness emitted per-query arrays.
        any_lats = any(len(lats_for(eng)) > 0 for eng in ENGINES)
        if not any_lats:
            lines.append("> **Per-query latencies missing** — this JSON was produced by the")
            lines.append("> pre-patch harness (`latencies_us` array not emitted). Bootstrap")
            lines.append("> over the {p50, p95, p99, avg} aggregates is parametric and not")
            lines.append("> reported here; re-run the bench with the patched harness to get")
            lines.append("> non-parametric CIs.\n")
            continue

        # Engine table
        lines.append(f"| Engine                 | n   | mean µs                | p50 µs                  | p95 µs                  |")
        lines.append(f"|------------------------|----:|------------------------|-------------------------|-------------------------|")
        for eng in ENGINES:
            arr_list = lats_for(eng)
            if not arr_list:
                ed = cfg.get(eng) or {}
                tag = "SKIP" if ed.get("skipped") else "—"
                lines.append(f"| `{eng:<22}` |  {tag}  | — | — | — |")
                continue
            arr = np.array(arr_list, dtype=np.float64)
            rng_a = np.random.default_rng(seed)
            mean = _bootstrap_mean(arr, B, rng_a)
            rng_b = np.random.default_rng(seed)
            p50 = _bootstrap_quantile(arr, 0.50, B, rng_b)
            rng_c = np.random.default_rng(seed)
            p95 = _bootstrap_quantile(arr, 0.95, B, rng_c)
            lines.append(
                f"| `{eng:<22}` | {len(arr):>3d} | {_fmt_us(*mean):<22} | {_fmt_us(*p50):<23} | {_fmt_us(*p95):<23} |"
            )
        lines.append("")

        # Headline ratio table only at the paper's reference operating point.
        if N == 20000:
            lines.append("**Headline ratios (paired-query bootstrap of median search latency)**\n")
            lines.append("| Numerator vs denominator                   | p50 ratio                         |")
            lines.append("|--------------------------------------------|-----------------------------------|")
            pairs = [
                ("dazzle_sq8", "objectbox",        "Dazzle SQ8 vs ObjectBox 4.x (HNSW vs HNSW)"),
                ("dazzle_sq8", "sqlite_vector_ai", "Dazzle SQ8 vs SQLiteAI precompute (HNSW vs SIMD scan)"),
                ("objectbox",  "sqlite_vector_ai", "ObjectBox 4.x vs SQLiteAI precompute"),
            ]
            for num_eng, den_eng, label in pairs:
                num_arr = lats_for(num_eng)
                den_arr = lats_for(den_eng)
                if not num_arr or not den_arr:
                    lines.append(f"| {label:<42} | — |")
                    continue
                rng_d = np.random.default_rng(seed)
                ratio = _bootstrap_paired_ratio(
                    np.array(num_arr, dtype=np.float64),
                    np.array(den_arr, dtype=np.float64),
                    B, rng_d,
                )
                lines.append(f"| {label:<42} | {_fmt_ratio(*ratio):<33} |")
            lines.append("")
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", type=Path, nargs="+", help="vecbench_*.json files")
    ap.add_argument("--B", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    args = ap.parse_args(argv)

    out_lines: list[str] = []
    out_lines.append("# Table 11 with bootstrap 95 % confidence intervals\n")
    out_lines.append(
        f"Bootstrap method: percentile, paired-query resampling for ratios. "
        f"`B = {args.B}`, seed = {args.seed}. Cells with `★` after the ratio "
        f"are statistically significant (95 % CI excludes 1.0).\n"
    )
    for p in args.paths:
        if not p.exists():
            print(f"WARNING: missing {p}", file=sys.stderr)
            continue
        out_lines.extend(process_json(p, args.B, args.seed))
    args.out.write_text("\n".join(out_lines), encoding="utf-8")
    try:
        rel_out = args.out.resolve().relative_to(REPO)
    except ValueError:
        rel_out = args.out
    print(f"Wrote {rel_out} ({len(out_lines)} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
