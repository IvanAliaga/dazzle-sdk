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
analyze_results.py — Generate paper-ready tables and figures from benchmark data.

Handles three JSON types produced by the Android experiment app:
  1. storage_only  — fast retrieval/ingest benchmark without Gemma
  2. full_experiment — full Gemma pipeline with recall/FPR/synthesis
  3. scale_benchmark — retrieval vs N (scale curve)

Usage:
    # Analyze all results for a device
    python3 research/scripts/analyze_results.py research/benchmarks/results/motorola_moto_g35_5G/

    # Analyze a specific results directory with output
    python3 research/scripts/analyze_results.py research/benchmarks/results/ --output research/paper_tables/

Outputs:
    - Markdown tables for the paper (§4.2, §5.1–§5.6)
    - LaTeX tables for direct inclusion
    - matplotlib charts (if available)
"""

import json
import math
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


# ─── Helpers ──────────────────────────────────────────────────────────────


def load_all_json(root: Path) -> list[dict]:
    """Recursively load all .json files under root."""
    results = []
    for p in sorted(root.rglob("*.json")):
        if p.name == "device_info.json":
            continue
        try:
            with open(p) as f:
                data = json.load(f)
            data["_source_file"] = str(p)
            results.append(data)
        except (json.JSONDecodeError, IOError) as e:
            print(f"  WARN: skipping {p}: {e}", file=sys.stderr)
    return results


def mean(vals: list[float]) -> float:
    return sum(vals) / len(vals) if vals else 0.0


def stdev(vals: list[float]) -> float:
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def fmt_us(v: float) -> str:
    if v >= 1000:
        return f"{v / 1000:.2f} ms"
    return f"{v:.1f} µs"


def fmt_mean_std(vals: list[float], unit: str = "µs") -> str:
    m = mean(vals)
    s = stdev(vals)
    if unit == "µs" and m >= 1000:
        return f"{m / 1000:.2f} ± {s / 1000:.2f} ms"
    return f"{m:.1f} ± {s:.1f} {unit}"


def pct(v: float) -> str:
    return f"{v * 100:.0f}%"


# ─── Storage-only analysis ────────────────────────────────────────────────


def analyze_storage_only(results: list[dict], out_dir: Path):
    """Table: retrieval latency × backends (mean ± σ)."""
    by_backend: dict[str, list[dict]] = defaultdict(list)
    for r in results:
        if r.get("type") != "storage_only":
            continue
        key = r.get("backend_key") or r.get("backend", "unknown")
        by_backend[key].append(r)

    if not by_backend:
        print("  No storage_only results found.")
        return

    # Sort backends: valkey variants first, then others
    valkey_order = [
        "valkey", "valkey-pipeline", "valkey-precompute",
        "valkey-lua", "valkey-hfe", "valkey-hll",
    ]
    other_order = [
        "sqlite",
        "sqlite-optimized",
        "sqlite-precompute",
        "rocksdb",
        "objectbox",
        "lmdb",
        "inmemory",
    ]
    all_backends = [b for b in valkey_order if b in by_backend]
    all_backends += [b for b in other_order if b in by_backend]
    all_backends += sorted(set(by_backend) - set(all_backends))

    device_name = "Unknown"
    for r in next(iter(by_backend.values())):
        dev = r.get("device", {})
        if isinstance(dev, dict):
            device_name = f"{dev.get('manufacturer', '')} {dev.get('model', '')}".strip()
        break

    # ── Markdown table ─────────────────────────────────────────────────
    lines = [
        f"## Table: Storage-Only Benchmark — {device_name}\n",
        f"*{sum(len(v) for v in by_backend.values())} runs across {len(by_backend)} backends*\n",
        "| Backend | Retrieval (µs) | P50 (µs) | P95 (µs) | Ingest (ms) | Per-ingest (µs) | Tokens (ctx) | Tokens (synth) | RAM Δ (KB) | IO Δ (bytes) |",
        "|---------|---------------|----------|----------|------------|----------------|-------------|---------------|-----------|-------------|",
    ]

    for bk in all_backends:
        runs = by_backend[bk]
        avg_ret = [r["avg_retrieval_us"] for r in runs]
        p50 = [r.get("p50_retrieval_us", 0) for r in runs]
        p95 = [r.get("p95_retrieval_us", 0) for r in runs]
        ingest = [r.get("ingest_total_ms", 0) for r in runs]
        per_ing = [r.get("per_ingest_us", 0) for r in runs]
        ctx_tok = [r.get("context_tokens_est", 0) for r in runs]
        syn_tok = [r.get("synth_tokens_est", 0) for r in runs]
        ram_d = [r.get("ram_delta_kb", 0) or 0 for r in runs]
        io_d = [r.get("io_write_bytes_delta", 0) or 0 for r in runs]

        name = runs[0].get("backend", bk)
        lines.append(
            f"| **{name}** "
            f"| {fmt_mean_std(avg_ret)} "
            f"| {mean(p50):.1f} "
            f"| {mean(p95):.1f} "
            f"| {fmt_mean_std(ingest, 'ms')} "
            f"| {mean(per_ing):.1f} "
            f"| ~{int(mean(ctx_tok))} "
            f"| ~{int(mean(syn_tok))} "
            f"| {int(mean(ram_d))} "
            f"| {int(mean(io_d))} |"
        )

    lines.append("")

    md_path = out_dir / "table_storage_only.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── LaTeX table ────────────────────────────────────────────────────
    latex_lines = [
        r"\begin{table}[ht]",
        r"\centering",
        r"\caption{Storage-Only Retrieval Latency — " + device_name + r"}",
        r"\label{tab:storage-only}",
        r"\begin{tabular}{lrrrrrr}",
        r"\toprule",
        r"Backend & Retrieval ($\mu$s) & P50 & P95 & Ingest (ms) & Ctx Tokens & IO $\Delta$ (B) \\",
        r"\midrule",
    ]
    for bk in all_backends:
        runs = by_backend[bk]
        name = runs[0].get("backend", bk)
        avg_ret = [r["avg_retrieval_us"] for r in runs]
        p50 = [r.get("p50_retrieval_us", 0) for r in runs]
        p95 = [r.get("p95_retrieval_us", 0) for r in runs]
        ingest = [r.get("ingest_total_ms", 0) for r in runs]
        ctx_tok = [r.get("context_tokens_est", 0) for r in runs]
        io_d = [r.get("io_write_bytes_delta", 0) or 0 for r in runs]
        latex_lines.append(
            f"  {name} & {mean(avg_ret):.1f} $\\pm$ {stdev(avg_ret):.1f} "
            f"& {mean(p50):.1f} & {mean(p95):.1f} "
            f"& {mean(ingest):.1f} "
            f"& {int(mean(ctx_tok))} "
            f"& {int(mean(io_d))} \\\\"
        )
    latex_lines += [r"\bottomrule", r"\end{tabular}", r"\end{table}"]
    latex_path = out_dir / "table_storage_only.tex"
    latex_path.write_text("\n".join(latex_lines) + "\n")
    print(f"  Written: {latex_path}")

    # ── Chart: retrieval latency bar chart ─────────────────────────────
    try:
        plot_retrieval_bars(by_backend, all_backends, out_dir, device_name)
    except ImportError:
        print("  matplotlib not available — skipping charts")


def plot_retrieval_bars(
    by_backend: dict, backends: list[str], out_dir: Path, device_name: str
):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    names = []
    means = []
    stds = []
    for bk in backends:
        runs = by_backend[bk]
        vals = [r["avg_retrieval_us"] for r in runs]
        names.append(runs[0].get("backend", bk))
        means.append(mean(vals))
        stds.append(stdev(vals))

    x = np.arange(len(names))
    fig, ax = plt.subplots(figsize=(12, 5))

    colors = []
    for n in names:
        if "Valkey" in n or "valkey" in n:
            colors.append("#e74c3c")
        else:
            colors.append("#3498db")

    bars = ax.bar(x, means, yerr=stds, capsize=3, color=colors, edgecolor="white")
    ax.set_ylabel("Retrieval Latency (µs)")
    ax.set_title(f"Context Retrieval Latency — {device_name}")
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=30, ha="right", fontsize=9)
    ax.yaxis.grid(True, linestyle="--", alpha=0.3)
    ax.set_axisbelow(True)

    for bar, m in zip(bars, means):
        ax.annotate(
            f"{m:.0f}",
            xy=(bar.get_x() + bar.get_width() / 2, bar.get_height()),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=8,
        )

    fig.tight_layout()
    chart_path = out_dir / "chart_retrieval_latency.png"
    fig.savefig(str(chart_path), dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Written: {chart_path}")


# ─── Full experiment analysis ─────────────────────────────────────────────


def analyze_full_experiment(results: list[dict], out_dir: Path):
    """Tables: recall, synthesis, and retrieval from full Gemma runs."""
    by_backend: dict[str, list[dict]] = defaultdict(list)
    for r in results:
        if r.get("type") == "full_experiment" or (
            "checkpoints" in r and "synthesis" in r
        ):
            key = r.get("backend", "valkey")
            by_backend[key].append(r)

    if not by_backend:
        print("  No full_experiment results found.")
        return

    all_backends = sorted(by_backend.keys())
    device_name = "Unknown"
    for r in next(iter(by_backend.values())):
        device_name = r.get("device", "Unknown")
        break

    # ── Recall / FPR table ─────────────────────────────────────────────
    lines = [
        f"## Table: Anomaly Detection — {device_name}\n",
        "| Backend | Recall (A) | Recall (B) | Δ Recall | FPR (A) | FPR (B) |",
        "|---------|-----------|-----------|---------|---------|---------|",
    ]
    for bk in all_backends:
        runs = by_backend[bk]
        metrics = [r.get("metrics", {}) for r in runs]
        recall_a = [m.get("recall_stateless", 0) for m in metrics]
        recall_b = [m.get("recall_augmented", 0) for m in metrics]
        fpr_a = [m.get("fpr_stateless", 0) for m in metrics]
        fpr_b = [m.get("fpr_augmented", 0) for m in metrics]
        delta = [b - a for a, b in zip(recall_a, recall_b)]
        lines.append(
            f"| **{bk}** "
            f"| {pct(mean(recall_a))} "
            f"| {pct(mean(recall_b))} "
            f"| {'+' if mean(delta) >= 0 else ''}{pct(mean(delta))} "
            f"| {pct(mean(fpr_a))} "
            f"| {pct(mean(fpr_b))} |"
        )
    lines.append("")

    md_path = out_dir / "table_recall.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── Synthesis table ────────────────────────────────────────────────
    lines = [
        f"## Table: Synthesis Accuracy — {device_name}\n",
        "| Backend | Stateless (/3) | Augmented (/3) | Δ |",
        "|---------|---------------|---------------|---|",
    ]
    for bk in all_backends:
        runs = by_backend[bk]
        metrics = [r.get("metrics", {}) for r in runs]
        sa = [m.get("synthesis_score_stateless", 0) for m in metrics]
        sb = [m.get("synthesis_score_augmented", 0) for m in metrics]
        delta = [b - a for a, b in zip(sa, sb)]
        lines.append(
            f"| **{bk}** "
            f"| {mean(sa):.1f} "
            f"| {mean(sb):.1f} "
            f"| {'+' if mean(delta) >= 0 else ''}{mean(delta):.1f} |"
        )
    lines.append("")

    md_path = out_dir / "table_synthesis.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── Retrieval latency from full runs ───────────────────────────────
    lines = [
        f"## Table: Retrieval Latency (Full Runs) — {device_name}\n",
        "| Backend | Valkey Retrieval (µs) | Avg Inference A (ms) | Avg Inference B (ms) | Avg Tokens A | Avg Tokens B |",
        "|---------|----------------------|---------------------|---------------------|-------------|-------------|",
    ]
    for bk in all_backends:
        runs = by_backend[bk]
        metrics = [r.get("metrics", {}) for r in runs]
        vk_lat = [m.get("valkey_avg_latency_us", 0) for m in metrics]
        inf_a = [m.get("avg_inference_ms_a", 0) for m in metrics]
        inf_b = [m.get("avg_inference_ms_b", 0) for m in metrics]
        tok_a = [m.get("avg_prompt_tokens_a", 0) for m in metrics]
        tok_b = [m.get("avg_prompt_tokens_b", 0) for m in metrics]
        lines.append(
            f"| **{bk}** "
            f"| {fmt_mean_std(vk_lat)} "
            f"| {mean(inf_a):.0f} "
            f"| {mean(inf_b):.0f} "
            f"| {mean(tok_a):.0f} "
            f"| {mean(tok_b):.0f} |"
        )
    lines.append("")

    md_path = out_dir / "table_retrieval_full.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")


# ─── Scale benchmark analysis ────────────────────────────────────────────


def analyze_scale(results: list[dict], out_dir: Path):
    """Tables and charts for the 7-axis scale benchmark."""
    by_backend: dict[str, list[dict]] = defaultdict(list)
    for r in results:
        if r.get("type") != "scale_benchmark":
            continue
        by_backend[r.get("backend", "unknown")].append(r)

    if not by_backend:
        print("  No scale_benchmark results found.")
        return

    all_backends = sorted(by_backend.keys())

    # Merge scale points across runs (average per N)
    merged: dict[str, dict[int, dict[str, list[float]]]] = {}
    for bk in all_backends:
        merged[bk] = defaultdict(lambda: defaultdict(list))
        for run in by_backend[bk]:
            for pt in run.get("scale_points", []):
                n = pt["n"]
                for key in [
                    "retrieval_avg_us", "retrieval_p50_us", "retrieval_p95_us",
                    "per_ingest_us", "ingest_total_ms",
                    "ram_delta_kb", "io_write_bytes_delta",
                    "context_tokens_est", "synth_tokens_est",
                    "concurrent_retrieval_avg_us", "concurrent_retrieval_p95_us",
                ]:
                    if key in pt and pt[key] is not None:
                        merged[bk][n][key].append(pt[key])

    # ── Scale table: retrieval vs N ────────────────────────────────────
    all_ns = sorted({n for bk in merged for n in merged[bk]})
    if not all_ns:
        print("  No scale points found.")
        return

    lines = [
        "## Table: Retrieval Latency vs N Readings\n",
        "| Backend | " + " | ".join(f"N={n}" for n in all_ns) + " |",
        "|---------|" + "|".join("-" * 12 for _ in all_ns) + "|",
    ]
    for bk in all_backends:
        row = [f"**{bk}**"]
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("retrieval_avg_us", [])
            if vals:
                row.append(f"{mean(vals):.1f} µs")
            else:
                row.append("—")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    md_path = out_dir / "table_scale_retrieval.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── Token efficiency table ─────────────────────────────────────────
    lines = [
        "## Table: Token Efficiency vs N Readings\n",
        "| Backend | " + " | ".join(f"N={n}" for n in all_ns) + " |",
        "|---------|" + "|".join("-" * 12 for _ in all_ns) + "|",
    ]
    for bk in all_backends:
        row = [f"**{bk}**"]
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("context_tokens_est", [])
            if vals:
                row.append(f"~{int(mean(vals))}")
            else:
                row.append("—")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    md_path = out_dir / "table_scale_tokens.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── Ingest throughput table ────────────────────────────────────────
    lines = [
        "## Table: Ingest Throughput vs N Readings\n",
        "| Backend | " + " | ".join(f"N={n}" for n in all_ns) + " |",
        "|---------|" + "|".join("-" * 12 for _ in all_ns) + "|",
    ]
    for bk in all_backends:
        row = [f"**{bk}**"]
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("per_ingest_us", [])
            if vals:
                row.append(f"{mean(vals):.1f} µs")
            else:
                row.append("—")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    md_path = out_dir / "table_scale_ingest.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── Concurrent read-write table ────────────────────────────────────
    lines = [
        "## Table: Concurrent Read-Write Retrieval Latency vs N\n",
        "| Backend | " + " | ".join(f"N={n}" for n in all_ns) + " |",
        "|---------|" + "|".join("-" * 12 for _ in all_ns) + "|",
    ]
    for bk in all_backends:
        row = [f"**{bk}**"]
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("concurrent_retrieval_avg_us", [])
            if vals:
                row.append(f"{mean(vals):.1f} µs")
            else:
                row.append("—")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    md_path = out_dir / "table_scale_concurrent.md"
    md_path.write_text("\n".join(lines) + "\n")
    print(f"  Written: {md_path}")

    # ── Charts ─────────────────────────────────────────────────────────
    try:
        plot_scale_charts(merged, all_backends, all_ns, out_dir)
    except ImportError:
        print("  matplotlib not available — skipping charts")


def plot_scale_charts(
    merged: dict, backends: list[str], all_ns: list[int], out_dir: Path
):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    valkey_colors = {
        "valkey": "#e74c3c",
        "valkey-pipeline": "#c0392b",
        "valkey-precompute": "#e67e22",
        "valkey-lua": "#f39c12",
        "valkey-hfe": "#d35400",
        "valkey-hll": "#e74c3c",
    }
    other_colors = {
        "sqlite": "#3498db",
        "sqlite-optimized": "#2980b9",
        "sqlite-precompute": "#1f77b4",
        "rocksdb": "#2ecc71",
        "objectbox": "#9b59b6",
        "lmdb": "#1abc9c",
        "inmemory": "#95a5a6",
    }
    all_colors = {**valkey_colors, **other_colors}

    def get_color(bk):
        return all_colors.get(bk, "#7f8c8d")

    # 1. Retrieval vs N (log scale)
    fig, ax = plt.subplots(figsize=(10, 6))
    for bk in backends:
        xs, ys = [], []
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("retrieval_avg_us", [])
            if vals:
                xs.append(n)
                ys.append(mean(vals))
        if xs:
            ax.plot(xs, ys, "o-", label=bk, color=get_color(bk), markersize=5)
    ax.set_xscale("log")
    ax.set_xlabel("N (number of readings)")
    ax.set_ylabel("Retrieval Latency (µs)")
    ax.set_title("Eje 1: Retrieval Latency vs Scale")
    ax.legend(fontsize=8, loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(str(out_dir / "chart_scale_retrieval.png"), dpi=150)
    plt.close(fig)
    print(f"  Written: {out_dir / 'chart_scale_retrieval.png'}")

    # 2. Token efficiency vs N
    fig, ax = plt.subplots(figsize=(10, 6))
    for bk in backends:
        xs, ys = [], []
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("context_tokens_est", [])
            if vals:
                xs.append(n)
                ys.append(mean(vals))
        if xs:
            ax.plot(xs, ys, "o-", label=bk, color=get_color(bk), markersize=5)
    ax.set_xscale("log")
    ax.set_xlabel("N (number of readings)")
    ax.set_ylabel("Context Block Tokens (est)")
    ax.set_title("Eje 7: Token Efficiency vs Scale")
    ax.legend(fontsize=8, loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(str(out_dir / "chart_scale_tokens.png"), dpi=150)
    plt.close(fig)
    print(f"  Written: {out_dir / 'chart_scale_tokens.png'}")

    # 3. Ingest throughput vs N
    fig, ax = plt.subplots(figsize=(10, 6))
    for bk in backends:
        xs, ys = [], []
        for n in all_ns:
            vals = merged[bk].get(n, {}).get("per_ingest_us", [])
            if vals:
                xs.append(n)
                ys.append(mean(vals))
        if xs:
            ax.plot(xs, ys, "o-", label=bk, color=get_color(bk), markersize=5)
    ax.set_xscale("log")
    ax.set_xlabel("N (number of readings)")
    ax.set_ylabel("Per-Ingest Latency (µs)")
    ax.set_title("Eje 3: Write Throughput vs Scale")
    ax.legend(fontsize=8, loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(str(out_dir / "chart_scale_ingest.png"), dpi=150)
    plt.close(fig)
    print(f"  Written: {out_dir / 'chart_scale_ingest.png'}")


# ─── Main ─────────────────────────────────────────────────────────────────


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_results.py <results_dir> [--output <dir>]")
        print("       python3 analyze_results.py research/benchmarks/results/motorola_moto_g35_5G/")
        sys.exit(1)

    results_root = Path(sys.argv[1])
    out_dir = results_root
    if "--output" in sys.argv:
        idx = sys.argv.index("--output")
        out_dir = Path(sys.argv[idx + 1])

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading results from: {results_root}")
    all_results = load_all_json(results_root)
    print(f"Loaded {len(all_results)} JSON files")

    # Classify
    storage_only = [r for r in all_results if r.get("type") == "storage_only"]
    full_exp = [
        r
        for r in all_results
        if r.get("type") == "full_experiment"
        or ("checkpoints" in r and "synthesis" in r)
    ]
    scale = [r for r in all_results if r.get("type") == "scale_benchmark"]
    print(
        f"  storage_only={len(storage_only)}, "
        f"full_experiment={len(full_exp)}, "
        f"scale={len(scale)}"
    )

    print("\n=== Storage-Only Analysis ===")
    analyze_storage_only(all_results, out_dir)

    print("\n=== Full Experiment Analysis ===")
    analyze_full_experiment(all_results, out_dir)

    print("\n=== Scale Benchmark Analysis ===")
    analyze_scale(all_results, out_dir)

    print(f"\nDone. Tables written to: {out_dir}")


if __name__ == "__main__":
    main()
