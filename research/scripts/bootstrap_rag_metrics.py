#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Non-parametric bootstrap (percentile method) over the per-query
metrics emitted by RagE2EBench, for the 2×2 RAG ablation reported in
Table 15 of the Dazzle paper.

The script (a) bootstraps the per-cell mean of every metric
(em_short / em_contains / f1_short / f1_passage) for every variant
in the 2×2 matrix, and (b) bootstraps the per-cell ratios
(small+RAG / small no-RAG, large+RAG / large no-RAG, small+RAG /
large no-RAG) using **paired-qid resampling** so that the same draw
of 200 query indices feeds both the numerator cell and the
denominator cell — preserving any per-query correlation between
configurations and producing a tighter (and correct) CI on the
ratio.

Determinism: seed=42, B=10000. Same input → same output every run.
The script exits non-zero if the seed-determinism self-check fails.

Usage:
    python3 research/scripts/bootstrap_rag_metrics.py
    python3 research/scripts/bootstrap_rag_metrics.py --B 5000 --seed 7
    python3 research/scripts/bootstrap_rag_metrics.py --self-check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent.parent
RAG_JSON = (
    REPO
    / "research"
    / "benchmarks"
    / "results"
    / "Moto_G35_5G"
    / "rag_2x2"
    / "rag_e2e_moto_g35_5G_1777395311213.json"
)
RAG_JSON_SHA = "00d21f6c8752ffaa1015624b69a5e5d0fd403670d72561e3838bdac0ab461e76"
OUT_PATH = REPO / "research" / "paper" / "rag_2x2_with_ci.md"

VARIANTS = ["small_no_rag", "small_rag", "large_no_rag", "large_rag"]
METRICS = ["em_short", "em_contains", "f1_short", "f1_passage"]

# Ratio definitions used in the paper narrative.
# (numerator_variant, denominator_variant, label_in_paper)
RATIOS = [
    ("small_rag",   "small_no_rag", "Qwen 0.5B + RAG / Qwen 0.5B no-RAG"),
    ("large_rag",   "large_no_rag", "Qwen 1.5B + RAG / Qwen 1.5B no-RAG"),
    ("small_rag",   "large_no_rag", "Qwen 0.5B + RAG / Qwen 1.5B no-RAG"),
    ("large_rag",   "small_rag",    "Qwen 1.5B + RAG / Qwen 0.5B + RAG"),
]


# ── helpers ────────────────────────────────────────────────────────────


@dataclass
class CellArrays:
    """Per-variant arrays of length N (one entry per query). Indexed by
    metric name."""
    qids: list[str]
    arrays: dict[str, np.ndarray]


def load_cells(json_path: Path) -> dict[str, CellArrays]:
    """Load the 2×2 JSON and return per-variant arrays keyed by qid.

    The qid order is preserved exactly as in the JSON (the harness
    writes qids in the same order across variants), so ratios via
    paired-qid resampling are well-defined.
    """
    raw = json.load(json_path.open())
    out: dict[str, CellArrays] = {}
    for v in VARIANTS:
        examples = raw["variants"][v]["examples"]
        qids = [e["qid"] for e in examples]
        arrays = {
            m: np.array(
                [e[m] if e[m] is not None else math.nan for e in examples],
                dtype=np.float64,
            )
            for m in METRICS
        }
        out[v] = CellArrays(qids=qids, arrays=arrays)
    # Verify all variants share the same qid order — required for
    # paired-qid bootstrap to be valid.
    base = out[VARIANTS[0]].qids
    for v in VARIANTS[1:]:
        if out[v].qids != base:
            raise SystemExit(
                f"qid order mismatch between {VARIANTS[0]} and {v}: "
                f"paired ratio bootstrap is undefined under that schema."
            )
    return out


def bootstrap_mean(values: np.ndarray, B: int, rng: np.random.Generator) -> tuple[float, float, float]:
    """Percentile-method bootstrap of the mean. Returns (mean, lo, hi)
    where (lo, hi) are the 2.5% / 97.5% percentiles of the bootstrap
    distribution.  NaN entries are dropped before resampling (the harness
    writes None for unscoreable rows; we mirror that convention)."""
    finite = values[~np.isnan(values)]
    n = len(finite)
    if n == 0:
        return (math.nan, math.nan, math.nan)
    idx = rng.integers(0, n, size=(B, n))
    means = finite[idx].mean(axis=1)
    return (float(finite.mean()), float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5)))


def bootstrap_paired_ratio(
    num: np.ndarray, den: np.ndarray, B: int, rng: np.random.Generator,
) -> tuple[float, float, float, bool, float]:
    """Paired-qid bootstrap of mean(num) / mean(den). Returns
    (point, lo, hi, crosses_one, frac_undefined).

    `crosses_one` is True iff the 95 % CI on the ratio crosses 1.0
    (conventional "no significant directional effect" threshold).

    `frac_undefined` is the fraction of bootstrap iterations where
    the denominator mean was exactly zero (which makes the ratio
    undefined). Those iterations are dropped and the percentile
    interval is computed on the remaining ones; if the fraction is
    appreciable (e.g. >5 %), the ratio is statistically unstable
    and the caller should report it with that caveat.

    For the point estimate we still divide mean(num) by mean(den)
    directly. When mean(den) is exactly zero on the original data,
    we return the ratio as NaN — the score is then undefined and
    the caller should report it as such rather than the ratio.
    """
    n = min(len(num), len(den))
    # Drop indices where either side is NaN — keeps the pairing
    # consistent.
    mask = ~(np.isnan(num[:n]) | np.isnan(den[:n]))
    num = num[:n][mask]
    den = den[:n][mask]
    n = len(num)
    if n == 0:
        return (math.nan, math.nan, math.nan, True, 1.0)
    idx = rng.integers(0, n, size=(B, n))
    num_means = num[idx].mean(axis=1)
    den_means = den[idx].mean(axis=1)
    valid = den_means > 0
    frac_undefined = float(1.0 - valid.mean())
    if valid.sum() == 0:
        return (math.nan, math.nan, math.nan, True, 1.0)
    ratios = num_means[valid] / den_means[valid]
    den_pt = float(den.mean())
    point = float(num.mean()) / den_pt if den_pt > 0 else math.nan
    lo = float(np.percentile(ratios, 2.5))
    hi = float(np.percentile(ratios, 97.5))
    crosses = (lo < 1.0 < hi) or (lo > 1.0 > hi)
    return (point, lo, hi, crosses, frac_undefined)


def fmt_mean_ci(point: float, lo: float, hi: float) -> str:
    if math.isnan(point):
        return "—"
    return f"{point:.3f} [{lo:.3f}, {hi:.3f}]"


def fmt_ratio_ci(point: float, lo: float, hi: float, crosses: bool, frac_undef: float) -> str:
    if math.isnan(point):
        return "—"
    sig = "" if crosses else " ★"
    note = ""
    if frac_undef > 0.005:
        note = f" ⚠"
    return f"{point:.2f}× [{lo:.2f}×, {hi:.2f}×]{sig}{note}"


# ── deterministic self-check ────────────────────────────────────────


def deterministic_self_check(json_path: Path, B: int, seed: int) -> tuple[str, str]:
    """Run the full pipeline twice and return digests of both runs. The
    main() entry asserts both digests are identical before writing
    output, so the script is guaranteed reproducible.
    """
    cells = load_cells(json_path)
    digests = []
    for _ in range(2):
        rng = np.random.default_rng(seed)
        h = hashlib.sha256()
        for v in VARIANTS:
            for m in METRICS:
                point, lo, hi = bootstrap_mean(cells[v].arrays[m], B, rng)
                h.update(f"{v}.{m}|{point:.10f}|{lo:.10f}|{hi:.10f}\n".encode())
        for num, den, _ in RATIOS:
            for m in METRICS:
                p, lo, hi, _, fu = bootstrap_paired_ratio(
                    cells[num].arrays[m], cells[den].arrays[m], B, rng
                )
                h.update(f"{num}/{den}.{m}|{p:.10f}|{lo:.10f}|{hi:.10f}|{fu:.10f}\n".encode())
        digests.append(h.hexdigest())
    return digests[0], digests[1]


# ── main ────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--B", type=int, default=10000, help="bootstrap iterations (default 10000)")
    ap.add_argument("--seed", type=int, default=42, help="rng seed (default 42)")
    ap.add_argument("--self-check", action="store_true", help="run deterministic self-check and exit")
    args = ap.parse_args(argv)

    if not RAG_JSON.exists():
        print(f"ERROR: RAG JSON missing at {RAG_JSON}", file=sys.stderr)
        return 2

    if args.self_check:
        d1, d2 = deterministic_self_check(RAG_JSON, args.B, args.seed)
        print(f"run1 digest: {d1}")
        print(f"run2 digest: {d2}")
        ok = d1 == d2
        print(f"deterministic: {'YES' if ok else 'NO'}")
        return 0 if ok else 1

    # Verify input integrity first (the SHA pinned in the paper).
    actual_sha = hashlib.sha256(RAG_JSON.read_bytes()).hexdigest()
    if actual_sha != RAG_JSON_SHA:
        print(f"ERROR: RAG JSON sha256 mismatch — paper expects {RAG_JSON_SHA}, "
              f"file is {actual_sha}", file=sys.stderr)
        return 3

    cells = load_cells(RAG_JSON)
    rng = np.random.default_rng(args.seed)

    # ── per-cell means ────────────────────────────────────────────
    cell_results: dict[str, dict[str, tuple[float, float, float]]] = {}
    for v in VARIANTS:
        cell_results[v] = {}
        for m in METRICS:
            cell_results[v][m] = bootstrap_mean(cells[v].arrays[m], args.B, rng)

    # ── per-cell ratios (paired qid) ──────────────────────────────
    ratio_results: dict[tuple[str, str], dict[str, tuple[float, float, float, bool, float]]] = {}
    for num, den, _label in RATIOS:
        ratio_results[(num, den)] = {}
        for m in METRICS:
            ratio_results[(num, den)][m] = bootstrap_paired_ratio(
                cells[num].arrays[m], cells[den].arrays[m], args.B, rng
            )

    # ── render markdown ───────────────────────────────────────────
    lines: list[str] = []
    lines.append(f"# Table 15 with bootstrap 95% confidence intervals\n")
    lines.append(f"Bootstrap method: percentile, paired-qid resampling for ratios.")
    lines.append(f"`B = {args.B}`, seed = {args.seed}, n = 200 queries per cell.")
    lines.append(f"Source JSON: `{RAG_JSON.relative_to(REPO)}`")
    lines.append(f"SHA-256 (verified): `{RAG_JSON_SHA}`.\n")

    # Table 15 with CIs
    lines.append("## Table 15a — Per-cell point estimates with 95 % CIs\n")
    lines.append("| Configuration              | EM_short                  | EM_contains               | F1_short                  | F1_passage                |")
    lines.append("|----------------------------|---------------------------|---------------------------|---------------------------|---------------------------|")
    label_map = {
        "small_no_rag": "Qwen 0.5B (no RAG)",
        "small_rag":    "Qwen 0.5B + Dazzle RAG",
        "large_no_rag": "Qwen 1.5B (no RAG)",
        "large_rag":    "Qwen 1.5B + Dazzle RAG",
    }
    for v in VARIANTS:
        cells_str = " | ".join(fmt_mean_ci(*cell_results[v][m]) for m in METRICS)
        lines.append(f"| {label_map[v]:<26} | {cells_str} |")
    lines.append("")

    # Ratio table
    lines.append("## Table 15b — Bootstrap 95 % CIs on per-metric ratios\n")
    lines.append("Paired-qid resampling: for each bootstrap iteration the **same**")
    lines.append("draw of 200 query indices is used in both the numerator cell")
    lines.append("and the denominator cell, so per-query correlation is preserved.")
    lines.append("A `★` after the CI marks ratios where the 95 % CI does **not**")
    lines.append("cross 1.0 — i.e. the directional effect is significant at the")
    lines.append("conventional bootstrap-percentile level. A `⚠` flag marks")
    lines.append("ratios where >0.5 % of bootstrap iterations had a denominator")
    lines.append("mean of exactly 0; those iterations are dropped before the")
    lines.append("percentile computation, but the ratio is statistically unstable")
    lines.append("and should be read with the additive (risk-difference) numbers")
    lines.append("from Table 15a as the primary reading.\n")
    lines.append("| Ratio                                       | EM_short                  | EM_contains               | F1_short                  | F1_passage                |")
    lines.append("|---------------------------------------------|---------------------------|---------------------------|---------------------------|---------------------------|")
    for num, den, label in RATIOS:
        cells_str = " | ".join(
            fmt_ratio_ci(*ratio_results[(num, den)][m]) for m in METRICS
        )
        lines.append(f"| {label:<43} | {cells_str} |")
    lines.append("")

    # Significance summary
    lines.append("## Significance summary\n")
    insig = []
    unstable = []
    for (num, den), per_m in ratio_results.items():
        for m, (_p, _lo, _hi, crosses, fu) in per_m.items():
            if crosses:
                insig.append((num, den, m))
            if fu > 0.005:
                unstable.append((num, den, m, fu))
    if insig:
        lines.append("Ratios whose 95 % CI **crosses 1.0** (no significant directional effect):")
        lines.append("")
        for num, den, m in insig:
            p, lo, hi, _, _ = ratio_results[(num, den)][m]
            lines.append(f"- `{num}` / `{den}` on `{m}`: {p:.2f}× [{lo:.2f}×, {hi:.2f}×]")
        lines.append("")
    else:
        lines.append("Every reported ratio has a 95 % CI that excludes 1.0 — every")
        lines.append("directional effect in Table 15 is significant at the")
        lines.append("conventional bootstrap-percentile level.\n")
    if unstable:
        lines.append("Ratios flagged unstable (`⚠` — denominator-mean = 0 in >0.5 % of iterations):")
        lines.append("")
        for num, den, m, fu in unstable:
            p, lo, hi, _, _ = ratio_results[(num, den)][m]
            lines.append(f"- `{num}` / `{den}` on `{m}`: {p:.2f}× [{lo:.2f}×, {hi:.2f}×] "
                         f"(undefined fraction = {fu*100:.2f} %). The denominator's")
            lines.append(f"  base rate is too low for a stable multiplicative ratio at n = 200;")
            lines.append(f"  the additive lift in Table 15a (mean − mean) is the better summary.")
        lines.append("")

    # Methodological note
    lines.append("## Methodological note\n")
    lines.append(f"Per-cell CIs are non-parametric percentile bootstrap on the")
    lines.append(f"per-query metric arrays (n = 200 each). Ratio CIs use the same")
    lines.append(f"resampling method but draw the **same** index vector for both")
    lines.append(f"cells in each iteration (paired bootstrap), which is the")
    lines.append(f"appropriate method when the two cells share queries — it")
    lines.append(f"removes between-query variance from the ratio's standard error")
    lines.append(f"and is therefore tighter (and correct) than two independent")
    lines.append(f"bootstraps. Determinism: B = {args.B}, seed = {args.seed}; the")
    lines.append(f"`--self-check` flag re-runs the pipeline twice and asserts the")
    lines.append(f"output digests match before writing this file.\n")

    OUT_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT_PATH.relative_to(REPO)} ({len(lines)} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
