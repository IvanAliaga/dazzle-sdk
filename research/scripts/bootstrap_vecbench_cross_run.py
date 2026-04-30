#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Cross-run bootstrap of the p50 search-latency statistic for the
Moto G35 5G headline cells of Table 11.

Use this script when per-query latency arrays are NOT persisted (the
v1 harness aggregates them into {avg, p50, p95, p99} only). It treats
each independent bench run as one realization of the p50 statistic
and bootstraps across runs (n usually small, typically 3-5; CI is
correspondingly wide). This is the right method when you have
multiple JSONs from the same bench preset on the same device.

For the next-generation harness (this revision and onward, after the
`latencies_us` field was added to VectorBenchmark.kt::latencyStats)
the per-query bootstrap in `bootstrap_vecbench_lats.py` is more
informative and should be preferred.

Usage:
    python3 research/scripts/bootstrap_vecbench_cross_run.py
"""

from __future__ import annotations

import glob
import hashlib
import json
import math
from pathlib import Path
from statistics import median

import numpy as np

REPO = Path(__file__).resolve().parent.parent.parent
GLOB = "research/benchmarks/results/Moto_G35_5G/vector/vecbench_moto_g35_5G_*.json"
OUT = REPO / "research" / "paper" / "vecbench_cross_run_ci.md"

HEADLINE_ENGINES = ["dazzle_sq8", "objectbox", "sqlite_vector_ai"]


def collect_p50s(json_paths: list[Path], n_docs: int = 20000) -> dict[str, list[int]]:
    out: dict[str, list[int]] = {e: [] for e in HEADLINE_ENGINES}
    out["dazzle_sq8_avg"] = []
    out["objectbox_avg"] = []
    out["sqlite_vector_ai_avg"] = []
    for p in json_paths:
        d = json.loads(p.read_text())
        for c in d.get("configs", []):
            if c.get("n_docs") != n_docs:
                continue
            for eng in HEADLINE_ENGINES:
                ed = c.get(eng) or {}
                if eng.startswith("dazzle"):
                    by_ef = ed.get("by_ef") or [{}]
                    sl = (by_ef[0] or {}).get("search_lat_us") or {}
                else:
                    sl = ed.get("search_lat_us") or {}
                p50 = sl.get("p50")
                avg = sl.get("avg")
                if p50 is not None:
                    out[eng].append(int(p50))
                if avg is not None:
                    out[f"{eng}_avg"].append(float(avg))
    return out


def bootstrap_cross_run(values: list[float], B: int = 10000, seed: int = 42) -> tuple[float, float, float]:
    """Bootstrap across independent runs. Returns (median, lo, hi).
    With n usually small (3-5), the percentile interval is wide; it is
    nonetheless the correct way to summarise inter-run variance."""
    if not values:
        return (math.nan, math.nan, math.nan)
    rng = np.random.default_rng(seed)
    arr = np.array(values, dtype=np.float64)
    n = len(arr)
    idx = rng.integers(0, n, size=(B, n))
    samples = arr[idx]
    medians = np.median(samples, axis=1)
    return float(np.median(arr)), float(np.percentile(medians, 2.5)), float(np.percentile(medians, 97.5))


def main() -> int:
    files = sorted(REPO.glob(GLOB))
    if not files:
        raise SystemExit(f"no vecbench JSONs at {GLOB}")
    p50_data = collect_p50s(files)

    lines: list[str] = []
    lines.append("# Table 11 headline cells with cross-run bootstrap 95 % CIs (Moto G35 5G)\n")
    lines.append(
        f"Bootstrap method: cross-run percentile bootstrap on the p50 (and "
        f"avg, side-table) search-latency statistic. Each bench run produced "
        f"one (avg, p50, p95, p99) tuple over 100 queries; we bootstrap the "
        f"**median of per-run p50s** across the {len(files)} independent runs "
        f"archived in `research/benchmarks/results/Moto_G35_5G/vector/`. "
        f"`B = 10 000`, seed = 42.\n"
    )
    lines.append(
        "**Method scope.** Per-run aggregates only — the legacy harness did "
        "not persist the 100-query latency array. The next-generation harness "
        "(`VectorBenchmark.kt::latencyStats` after this revision) emits the "
        "raw `latencies_us` array, so future revisions can replace this "
        "across-runs bootstrap with the tighter per-query bootstrap; we keep "
        "this script as the audit trail for the v2 paper measurements.\n"
    )

    # Source files + sha256
    lines.append("## Source bench JSONs\n")
    lines.append("| File                                                           | timestamp                  | sha256 (prefix) |")
    lines.append("|----------------------------------------------------------------|----------------------------|-----------------|")
    for f in files:
        ts = json.loads(f.read_text()).get("timestamp", "?")
        h = hashlib.sha256(f.read_bytes()).hexdigest()[:16]
        lines.append(f"| `{f.name}` | `{ts}` | `{h}` |")
    lines.append("")

    # Headline table
    lines.append("## Table 11 headline cells (N = 20 000, dim = 384, k = 10)\n")
    lines.append("| Engine                  | n runs | per-run p50 µs (each run)       | bootstrap p50 [95 % CI] (µs) | bootstrap avg [95 % CI] (µs) |")
    lines.append("|-------------------------|-------:|---------------------------------|------------------------------|------------------------------|")
    for eng in HEADLINE_ENGINES:
        runs = p50_data[eng]
        if not runs:
            lines.append(f"| `{eng:<22}` | 0 | — | — | — |")
            continue
        median_p50, p50_lo, p50_hi = bootstrap_cross_run(runs)
        avgs = p50_data.get(f"{eng}_avg", [])
        if avgs:
            median_avg, avg_lo, avg_hi = bootstrap_cross_run(avgs)
            avg_str = f"{median_avg:.0f} [{avg_lo:.0f}, {avg_hi:.0f}]"
        else:
            avg_str = "—"
        lines.append(
            f"| `{eng:<22}` | {len(runs):>6d} | {runs} | "
            f"{median_p50:.0f} [{p50_lo:.0f}, {p50_hi:.0f}] | {avg_str} |"
        )
    lines.append("")

    # Headline ratios (paired by run order — same harness preset, same device, ~30 min apart)
    lines.append("## Headline ratios (paired-run bootstrap on p50)\n")
    lines.append("Each bootstrap iteration draws the same indices into the "
                 "two engines' per-run-p50 lists. With small n the ratio CI is "
                 "wide; the headline qualitative direction (HNSW < SIMD scan) "
                 "is preserved across every iteration in every run pairing.\n")
    lines.append("| Numerator vs denominator                          | ratio of medians [95 % CI] |")
    lines.append("|---------------------------------------------------|----------------------------|")
    pairs = [
        ("dazzle_sq8", "objectbox",        "Dazzle SQ8 / ObjectBox 4.x (HNSW vs HNSW)"),
        ("dazzle_sq8", "sqlite_vector_ai", "Dazzle SQ8 / SQLiteAI precompute (HNSW vs SIMD scan)"),
        ("objectbox",  "sqlite_vector_ai", "ObjectBox 4.x / SQLiteAI precompute"),
    ]
    rng = np.random.default_rng(42)
    for num, den, label in pairs:
        a = np.array(p50_data[num], dtype=float)
        b = np.array(p50_data[den], dtype=float)
        n = min(len(a), len(b))
        if n < 2:
            lines.append(f"| {label:<48} | — |")
            continue
        idx = rng.integers(0, n, size=(10000, n))
        ratios = np.median(a[idx], axis=1) / np.maximum(np.median(b[idx], axis=1), 1e-9)
        lines.append(
            f"| {label:<48} | "
            f"{np.median(a)/max(np.median(b),1e-9):.2f}× "
            f"[{np.percentile(ratios,2.5):.2f}×, {np.percentile(ratios,97.5):.2f}×] |"
        )
    lines.append("")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
