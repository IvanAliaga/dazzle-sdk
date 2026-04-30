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

"""plot_ablation_sweep.py — render the ablation-sweep JSON as paper tables
and matplotlib figures.

Usage:
    python3 research/scripts/plot_ablation_sweep.py \
        research/benchmarks/results/ablation/ablation_sweep_*.json

For every input file the script emits next to it:
    <basename>.throughput.png   — ops/s vs K, one line per (variant × backend)
    <basename>.p99.png          — p99 latency vs K, same grouping
    <basename>.table.md         — Markdown table ready to paste in the paper
    <basename>.contribution.png — contribution-by-layer bar chart per backend
                                  (only when the sweep uses the variant axis)
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:  # pragma: no cover
    sys.stderr.write("matplotlib required: pip install matplotlib\n")
    sys.exit(2)


def _load(path: Path) -> dict:
    with path.open() as f:
        return json.load(f)


def _cell_top_axis(c: dict) -> str:
    """variant if present (new sweep format), else mode (legacy)."""
    return c.get("variant") or c.get("mode") or "?"


def _grouped(cells: list[dict]) -> dict[tuple[str, str], list[dict]]:
    """Group by (variant|mode, backend); within a group, sort by K."""
    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for c in cells:
        groups[(_cell_top_axis(c), c["backend"])].append(c)
    for g in groups.values():
        g.sort(key=lambda c: c["k"])
    return groups


def _plot_axis(groups: dict, field_getter, ylabel: str, out: Path,
               title: str, logy: bool = False) -> None:
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for (top, backend), cells in sorted(groups.items()):
        xs = [c["k"] for c in cells]
        ys = [field_getter(c) for c in cells]
        label = f"{backend} / {top}"
        ax.plot(xs, ys, marker="o", label=label)
    ax.set_xlabel("Concurrent agents (K)")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.set_xscale("log", base=2)
    if logy:
        ax.set_yscale("log")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best", fontsize=7)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def _plot_contribution(cells: list[dict], variants: list[str],
                       out: Path, device: str) -> None:
    """Bar chart: at highest K, show each variant's ops/s per backend.

    This is the paper's "contribution of each optimization layer" figure.
    """
    # Use the top K value in the sweep to measure steady-state.
    max_k = max(c["k"] for c in cells)
    filt = [c for c in cells if c["k"] == max_k]

    backends = sorted({c["backend"] for c in filt})
    if not backends or not variants:
        return

    width = 0.8 / max(1, len(variants))
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for vi, v in enumerate(variants):
        ys = []
        for bi, b in enumerate(backends):
            match = next((c for c in filt
                          if _cell_top_axis(c) == v and c["backend"] == b), None)
            ys.append(match["ops_per_sec"] if match else 0)
        xs = [bi + vi * width - 0.4 + width/2 for bi in range(len(backends))]
        ax.bar(xs, ys, width, label=v)
    ax.set_xticks(range(len(backends)))
    ax.set_xticklabels(backends)
    ax.set_ylabel(f"Throughput at K={max_k} (ops/s)")
    ax.set_title(f"Ablation — contribution by layer ({device})")
    ax.grid(axis="y", alpha=0.3)
    ax.legend(loc="best", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def _table(cells: list[dict]) -> str:
    """Markdown table: one row per cell, sorted (backend, variant/mode, K)."""
    has_variant = any(c.get("variant") for c in cells)
    top_label = "Variant" if has_variant else "Mode"
    rows = sorted(cells, key=lambda c: (c["backend"], _cell_top_axis(c), c["k"]))
    lines = [
        f"| Backend | {top_label} | K | Ops/s | p50 µs | p95 µs | p99 µs | Reads | Writes |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for c in rows:
        lat = c["latency_us"]
        lines.append(
            f"| {c['backend']} | {_cell_top_axis(c)} | {c['k']} | "
            f"{c['ops_per_sec']:.0f} | {lat['p50']:.1f} | {lat['p95']:.1f} | "
            f"{lat['p99']:.1f} | {c['reads']} | {c['writes']} |"
        )
    return "\n".join(lines) + "\n"


def _process(in_path: Path) -> None:
    payload = _load(in_path)
    cells = payload.get("cells", [])
    if not cells:
        sys.stderr.write(f"{in_path}: no cells\n")
        return

    groups = _grouped(cells)
    stem = in_path.with_suffix("")   # drop .json
    device = payload.get("device", "")

    _plot_axis(
        groups,
        field_getter=lambda c: c["ops_per_sec"],
        ylabel="Throughput (ops/s)",
        out=stem.with_suffix(".throughput.png"),
        title=f"Ablation sweep — throughput ({device})",
    )
    _plot_axis(
        groups,
        field_getter=lambda c: c["latency_us"]["p99"],
        ylabel="Latency p99 (µs)",
        out=stem.with_suffix(".p99.png"),
        title=f"Ablation sweep — p99 latency ({device})",
        logy=True,
    )

    # Contribution-by-layer chart only if the sweep has the variant axis.
    variants_meta = payload.get("variants", [])
    variant_names = [v["name"] for v in variants_meta]
    if variant_names:
        _plot_contribution(cells, variant_names,
                           stem.with_suffix(".contribution.png"), device)

    table_md = _table(cells)
    stem.with_suffix(".table.md").write_text(table_md)

    extras = ".contribution.png, " if variant_names else ""
    print(f"✓ {in_path.name} → {stem.name}.{{throughput,p99}}.png, {extras}.table.md")


def _aggregate(in_paths: list[Path], out_stem: Path) -> None:
    """Merge cells + variants metadata from multiple per-variant JSONs.

    The external shell driver writes one JSON per variant (it restarts the
    host process between variants to work around in-process valkey_main
    fragility). This aggregator produces the unified figures and table.
    """
    all_cells: list[dict] = []
    variants: list[dict] = []
    device = ""
    seen_variants: set[str] = set()
    for p in in_paths:
        d = _load(p)
        device = device or d.get("device", "")
        all_cells.extend(d.get("cells", []))
        for v in d.get("variants", []):
            if v["name"] not in seen_variants:
                variants.append(v)
                seen_variants.add(v["name"])

    if not all_cells:
        sys.stderr.write("aggregate: no cells found across inputs\n")
        return

    groups = _grouped(all_cells)

    _plot_axis(
        groups,
        field_getter=lambda c: c["ops_per_sec"],
        ylabel="Throughput (ops/s)",
        out=out_stem.with_suffix(".throughput.png"),
        title=f"Ablation sweep — throughput ({device})",
    )
    _plot_axis(
        groups,
        field_getter=lambda c: c["latency_us"]["p99"],
        ylabel="Latency p99 (µs)",
        out=out_stem.with_suffix(".p99.png"),
        title=f"Ablation sweep — p99 latency ({device})",
        logy=True,
    )
    if variants:
        _plot_contribution(all_cells, [v["name"] for v in variants],
                           out_stem.with_suffix(".contribution.png"), device)

    out_stem.with_suffix(".table.md").write_text(_table(all_cells))
    print(f"✓ aggregated {len(in_paths)} file(s) → {out_stem.name}.{{throughput,p99,contribution}}.png + .table.md")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("inputs", nargs="+", help="One or more ablation_sweep_*.json")
    ap.add_argument("--aggregate", metavar="STEM", default=None,
                    help="Merge all inputs into one figure set named <STEM>.{throughput,p99,contribution}.png")
    args = ap.parse_args()

    paths = []
    for inp in args.inputs:
        p = Path(inp)
        if not p.exists():
            sys.stderr.write(f"missing: {inp}\n")
            continue
        paths.append(p)

    if args.aggregate:
        _aggregate(paths, Path(args.aggregate))
    else:
        for p in paths:
            _process(p)


if __name__ == "__main__":
    main()
