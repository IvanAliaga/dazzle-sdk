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

"""analyze_tfi_operating_curve.py — derive the TFI operating curve and the
empirical signal-calibration table from a single experiment_android_*.json.

The Android LLM experiment records, for every checkpoint, the continuous
`rule_prediction.probability` produced by the TFI module along with the
set of symbolic signals that fired. Sweeping a decision threshold over the
probability yields a recall / FPR curve — the Bayes-optimal achievable
performance envelope for the feature set. Marking the OR+Bayesian-gate
operating point on that curve shows where the shipped primitive sits.

The same JSON lets us reconstruct the posterior table that TFI.EXPLAIN
would return at end-of-run: for each named signal we count how often the
signal fired on a checkpoint whose NEXT window contained a fault (hit)
versus one that did not (miss). The Beta-posterior confidence (with the
engine's Beta(2,3) prior) is the empirical calibration score.

Usage:
    python3 research/scripts/analyze_tfi_operating_curve.py \
        path/to/experiment_android_*.json [--out out_prefix]

Outputs (next to the JSON when --out is omitted):
    <prefix>.roc.csv           — threshold, TP, FP, TN, FN, recall, FPR
    <prefix>.roc.png           — ROC plot with operating point
    <prefix>.calibration.md    — Markdown calibration table for the paper
    <prefix>.summary.md        — one-paragraph numeric summary
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# Beta prior matching sdk/android/src/main/cpp/tfi_module.c
BETA_PRIOR_ALPHA = 2.0
BETA_PRIOR_BETA = 3.0


def load_checkpoints(json_path: Path) -> list[dict]:
    with json_path.open() as fh:
        data = json.load(fh)
    cps = data.get("checkpoints") or data.get("cps") or []
    if not cps:
        raise SystemExit(f"no 'checkpoints' array in {json_path}")
    return cps


def build_prediction_table(cps: list[dict]) -> list[dict]:
    """Align each CP's prediction with the ground truth of the NEXT window.

    The engine at CP_i predicts whether CP_{i+1}'s window will contain a
    fault. The last CP has no ground truth and is skipped.
    """
    rows = []
    for i in range(len(cps) - 1):
        rp = cps[i].get("rule_prediction") or {}
        prob = rp.get("probability")
        fired = rp.get("fired_signals") or []
        ruled = bool(rp.get("predicted"))
        actual_next = bool(cps[i + 1].get("window_has_anomaly"))
        rows.append(
            dict(
                cp_index=i,
                minute=cps[i].get("minute"),
                probability=float(prob) if prob is not None else 0.0,
                fired=list(fired),
                rule_predicted=ruled,
                actual_next_fault=actual_next,
            )
        )
    return rows


def sweep_threshold(rows: list[dict], thresholds: list[float]) -> list[dict]:
    out = []
    for t in thresholds:
        tp = fp = tn = fn = 0
        for r in rows:
            pred = r["probability"] >= t
            if pred and r["actual_next_fault"]:
                tp += 1
            elif pred and not r["actual_next_fault"]:
                fp += 1
            elif not pred and r["actual_next_fault"]:
                fn += 1
            else:
                tn += 1
        recall = tp / (tp + fn) if (tp + fn) else 0.0
        fpr = fp / (fp + tn) if (fp + tn) else 0.0
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        out.append(
            dict(
                threshold=round(t, 4),
                tp=tp,
                fp=fp,
                tn=tn,
                fn=fn,
                recall=recall,
                fpr=fpr,
                precision=precision,
            )
        )
    return out


def auc_trapezoid(points: list[tuple[float, float]]) -> float:
    """Integrate recall dFPR via trapezoid rule. Points must be (fpr, recall)."""
    pts = sorted(points)
    # Anchor at (0,0) and (1,1) so the curve is a valid ROC endpoint-to-endpoint.
    if pts[0] != (0.0, 0.0):
        pts.insert(0, (0.0, 0.0))
    if pts[-1] != (1.0, 1.0):
        pts.append((1.0, 1.0))
    x = [p[0] for p in pts]
    y = [p[1] for p in pts]
    trapz = getattr(np, "trapezoid", None) or np.trapz
    return float(trapz(y, x))


def compute_current_point(rows: list[dict]) -> tuple[int, int, int, int]:
    tp = fp = tn = fn = 0
    for r in rows:
        if r["rule_predicted"] and r["actual_next_fault"]:
            tp += 1
        elif r["rule_predicted"] and not r["actual_next_fault"]:
            fp += 1
        elif not r["rule_predicted"] and r["actual_next_fault"]:
            fn += 1
        else:
            tn += 1
    return tp, fp, tn, fn


def build_calibration_table(rows: list[dict]) -> list[dict]:
    """Count hits / misses per signal across all observed CPs and compute the
    Beta(2,3) posterior confidence that TFI.EXPLAIN would report."""
    by_signal: dict[str, dict[str, int]] = {}
    for r in rows:
        actual = r["actual_next_fault"]
        for sig in r["fired"]:
            b = by_signal.setdefault(sig, {"hits": 0, "misses": 0, "fires": 0})
            b["fires"] += 1
            if actual:
                b["hits"] += 1
            else:
                b["misses"] += 1
    out = []
    for sig, s in sorted(by_signal.items(), key=lambda kv: -kv[1]["fires"]):
        a = s["hits"] + BETA_PRIOR_ALPHA
        b = s["misses"] + BETA_PRIOR_BETA
        conf = a / (a + b)
        out.append(
            dict(
                signal=sig,
                fires=s["fires"],
                hits=s["hits"],
                misses=s["misses"],
                posterior=round(conf, 3),
            )
        )
    return out


def write_roc_csv(out_path: Path, sweep: list[dict]) -> None:
    with out_path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(sweep[0].keys()))
        w.writeheader()
        w.writerows(sweep)


def render_roc(
    out_path: Path,
    sweep: list[dict],
    current_point: tuple[int, int, int, int],
    auc: float,
    title: str,
) -> None:
    fpr = [r["fpr"] for r in sweep]
    recall = [r["recall"] for r in sweep]
    # Sort by FPR ascending for a monotone ROC trace.
    order = sorted(range(len(sweep)), key=lambda i: (fpr[i], recall[i]))
    fpr_s = [fpr[i] for i in order]
    rec_s = [recall[i] for i in order]

    tp, fp, tn, fn = current_point
    cur_fpr = fp / (fp + tn) if (fp + tn) else 0.0
    cur_rec = tp / (tp + fn) if (tp + fn) else 0.0

    fig, ax = plt.subplots(figsize=(6, 5))
    ax.plot(fpr_s, rec_s, "-o", markersize=3, linewidth=1.5,
            label=f"TFI probability sweep (AUC={auc:.3f})")
    ax.plot([0, 1], [0, 1], "--", color="gray", alpha=0.5, label="random")
    ax.scatter([cur_fpr], [cur_rec], color="red", s=80, zorder=5,
               label=f"OR + Bayesian gate (FPR={cur_fpr:.2f}, recall={cur_rec:.2f})")
    ax.set_xlabel("False Positive Rate")
    ax.set_ylabel("Recall (True Positive Rate)")
    ax.set_title(title)
    ax.set_xlim(-0.02, 1.02)
    ax.set_ylim(-0.02, 1.02)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="lower right", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_path, dpi=140)
    plt.close(fig)


def write_calibration_md(out_path: Path, table: list[dict]) -> None:
    lines = [
        "| Signal | Fires | Hits | Misses | Beta posterior |",
        "|---|---:|---:|---:|---:|",
    ]
    for r in table:
        lines.append(
            f"| `{r['signal']}` | {r['fires']} | {r['hits']} | {r['misses']} | {r['posterior']:.3f} |"
        )
    out_path.write_text("\n".join(lines) + "\n")


def write_summary_md(
    out_path: Path,
    json_path: Path,
    rows: list[dict],
    sweep: list[dict],
    current_point: tuple[int, int, int, int],
    auc: float,
) -> None:
    tp, fp, tn, fn = current_point
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    fpr = fp / (fp + tn) if (fp + tn) else 0.0
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    # Best operating point by F1
    def f1(r):
        p = r["precision"]
        rc = r["recall"]
        return (2 * p * rc) / (p + rc) if (p + rc) else 0.0
    best = max(sweep, key=f1)
    lines = [
        f"# TFI operating curve — {json_path.name}",
        "",
        f"- Checkpoints evaluated (with next-window ground truth): **{len(rows)}**",
        f"- Positives / Negatives: **{sum(r['actual_next_fault'] for r in rows)} / "
        f"{sum(not r['actual_next_fault'] for r in rows)}**",
        "",
        f"## Shipped operating point (OR rule + Bayesian gate)",
        f"- TP={tp} FP={fp} TN={tn} FN={fn}",
        f"- Recall **{recall:.3f}** · FPR **{fpr:.3f}** · Precision **{precision:.3f}**",
        "",
        f"## Probability sweep",
        f"- ROC AUC (trapezoid): **{auc:.3f}**",
        f"- Best-F1 threshold: **{best['threshold']:.2f}** → "
        f"recall {best['recall']:.3f}, FPR {best['fpr']:.3f}, "
        f"precision {best['precision']:.3f}",
        "",
        "The shipped point is a single operating choice on the probability ",
        "curve; different deployments can select a different threshold ",
        "without retraining.",
    ]
    out_path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("json_path", type=Path)
    ap.add_argument("--out", type=Path, default=None,
                    help="output prefix (default: strip .json from input)")
    args = ap.parse_args()

    if not args.json_path.exists():
        print(f"not found: {args.json_path}", file=sys.stderr)
        return 1

    prefix = args.out or args.json_path.with_suffix("")
    prefix.parent.mkdir(parents=True, exist_ok=True)

    cps = load_checkpoints(args.json_path)
    rows = build_prediction_table(cps)

    thresholds = [round(x, 2) for x in np.arange(0.0, 1.01, 0.05)]
    sweep = sweep_threshold(rows, thresholds)
    auc = auc_trapezoid([(r["fpr"], r["recall"]) for r in sweep])
    current = compute_current_point(rows)
    calibration = build_calibration_table(rows)

    write_roc_csv(prefix.with_suffix(".roc.csv"), sweep)
    render_roc(
        prefix.with_suffix(".roc.png"),
        sweep,
        current,
        auc,
        title=f"TFI operating curve — {args.json_path.stem}",
    )
    write_calibration_md(prefix.with_suffix(".calibration.md"), calibration)
    write_summary_md(
        prefix.with_suffix(".summary.md"),
        args.json_path,
        rows,
        sweep,
        current,
        auc,
    )

    tp, fp, tn, fn = current
    print(f"checkpoints         : {len(rows)}")
    print(f"shipped operating   : TP={tp} FP={fp} TN={tn} FN={fn} "
          f"recall={tp/(tp+fn) if tp+fn else 0:.3f} "
          f"FPR={fp/(fp+tn) if fp+tn else 0:.3f}")
    print(f"ROC AUC             : {auc:.3f}")
    print(f"outputs             : {prefix}.roc.csv / .roc.png / "
          ".calibration.md / .summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
