#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""
HNSW parity harness — Fase 1 closure (PIVOT_PLAN §4).

Generates a deterministic gaussian vector dataset (seeded) and computes
exact brute-force top-k ground truth with numpy. Runs the upstream
hnswlib x86 reference implementation with the same (M, efConstruction)
that the on-device module uses (M=16, efC=200) across an ef sweep, and
reports recall@10 + latency per (N, ef) pair. The same binary files are
consumed by the Android HnswParityBench, so the on-device run is a
bit-exact apples-to-apples parity check — any |Δrecall| > 2 % signals a
port bug in `valkeysearch_module.cc`.

Binary file layout (little-endian):
    vecs_n{N}.bin, queries.bin:
        uint32 rows, uint32 cols, float32[rows * cols]
    gt_n{N}_k10.bin:
        uint32 rows, uint32 k,    int32[rows * k]

Invocation:
    source research/.venv-hnsw/bin/activate
    python research/scripts/hnsw_parity.py --out research/data/hnsw_parity \
        --results research/results/hnsw_parity_x86.json
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Iterable

import hnswlib
import numpy as np

DIM        = 384
SEED       = 42
SIZES      = (1_000, 10_000, 100_000)
N_QUERIES  = 1_000
K          = 10
M          = 16
EF_CONSTR  = 200
EF_SWEEP   = (16, 32, 64, 128, 256, 512)


# ── Binary IO ────────────────────────────────────────────────────────────────

def write_f32(path: Path, arr: np.ndarray) -> None:
    """Write 2D float32 matrix with (rows, cols) uint32 header."""
    assert arr.dtype == np.float32 and arr.ndim == 2
    rows, cols = arr.shape
    with path.open("wb") as f:
        f.write(np.array([rows, cols], dtype="<u4").tobytes())
        f.write(np.ascontiguousarray(arr).tobytes())


def write_i32(path: Path, arr: np.ndarray) -> None:
    assert arr.dtype == np.int32 and arr.ndim == 2
    rows, cols = arr.shape
    with path.open("wb") as f:
        f.write(np.array([rows, cols], dtype="<u4").tobytes())
        f.write(np.ascontiguousarray(arr).tobytes())


# ── Data generation ─────────────────────────────────────────────────────────

def make_data(n_docs: int, n_queries: int, dim: int, seed: int):
    """Gaussian N(0, 1) docs + held-out queries. Raw (not normalised) —
    both the x86 hnswlib path and the on-device module normalise at insert
    time, so we keep the raw bytes on disk to avoid any rounding drift."""
    rng = np.random.default_rng(seed)
    docs    = rng.standard_normal(size=(n_docs,    dim), dtype=np.float32)
    queries = rng.standard_normal(size=(n_queries, dim), dtype=np.float32)
    return docs, queries


def brute_force_topk(docs: np.ndarray, queries: np.ndarray, k: int) -> np.ndarray:
    """Exact cosine top-k via matmul on L2-normalised copies."""
    dn = docs  / np.linalg.norm(docs,  axis=1, keepdims=True).clip(min=1e-12)
    qn = queries / np.linalg.norm(queries, axis=1, keepdims=True).clip(min=1e-12)
    sims = qn @ dn.T
    idx  = np.argpartition(-sims, kth=k - 1, axis=1)[:, :k]
    # Sort the k by score so the top-1 is deterministic
    row_sims = np.take_along_axis(sims, idx, axis=1)
    order    = np.argsort(-row_sims, axis=1)
    topk     = np.take_along_axis(idx, order, axis=1).astype(np.int32)
    return topk


# ── hnswlib x86 run ─────────────────────────────────────────────────────────

def run_hnswlib_x86(docs: np.ndarray, queries: np.ndarray, gt: np.ndarray,
                    ef_sweep: Iterable[int]):
    """Build index once at (M, efC), then sweep ef_runtime. Returns a list
    of per-ef dicts with recall@k and latency stats."""
    n, dim = docs.shape
    k      = gt.shape[1]

    p = hnswlib.Index(space="cosine", dim=dim)
    p.init_index(max_elements=n, ef_construction=EF_CONSTR, M=M, random_seed=SEED)
    p.set_num_threads(1)  # latency numbers should be single-threaded

    t0 = time.perf_counter()
    p.add_items(docs, ids=np.arange(n, dtype=np.int64))
    build_s = time.perf_counter() - t0

    out = []
    for ef in ef_sweep:
        p.set_ef(ef)
        lat_us = []
        correct = 0
        for qi in range(queries.shape[0]):
            t1 = time.perf_counter_ns()
            labels, _ = p.knn_query(queries[qi:qi + 1], k=k)
            lat_us.append((time.perf_counter_ns() - t1) / 1_000.0)
            pred = set(labels[0].tolist())
            gold = set(gt[qi].tolist())
            correct += len(pred & gold)
        recall = correct / (queries.shape[0] * k)
        lat = np.asarray(lat_us)
        out.append({
            "ef": ef,
            "recall_at_k": float(recall),
            "latency_us": {
                "n":   int(lat.size),
                "avg": float(lat.mean()),
                "p50": float(np.percentile(lat, 50)),
                "p95": float(np.percentile(lat, 95)),
                "p99": float(np.percentile(lat, 99)),
                "min": float(lat.min()),
                "max": float(lat.max()),
            },
        })
    return build_s, out


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out",     required=True, help="dir for binary dataset")
    ap.add_argument("--results", required=True, help="json path for x86 run")
    ap.add_argument("--sizes",   type=int, nargs="+", default=list(SIZES))
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # One shared query set across all sizes so we can reuse GT indices with
    # the same query rows.
    queries = np.random.default_rng(SEED + 1).standard_normal(
        size=(N_QUERIES, DIM), dtype=np.float32,
    )
    write_f32(out_dir / "queries.bin", queries)

    manifest = {
        "dim": DIM, "seed": SEED, "m": M, "ef_construction": EF_CONSTR,
        "ef_sweep": list(EF_SWEEP), "k": K, "n_queries": N_QUERIES,
        "sizes": args.sizes,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    x86_report = {
        "dim": DIM, "seed": SEED, "m": M, "ef_construction": EF_CONSTR,
        "k": K, "n_queries": N_QUERIES,
        "hnswlib_version": getattr(hnswlib, "__version__", "unknown"),
        "numpy_version":   np.__version__,
        "per_n": {},
    }

    for n in args.sizes:
        print(f"── N={n:>6d} ──")
        docs, _ = make_data(n, N_QUERIES, DIM, SEED)
        write_f32(out_dir / f"vecs_n{n}.bin", docs)

        print(f"  brute-force GT … ", end="", flush=True)
        t0 = time.perf_counter()
        gt = brute_force_topk(docs, queries, K)
        print(f"{(time.perf_counter() - t0):.2f}s")
        write_i32(out_dir / f"gt_n{n}_k{K}.bin", gt)

        print(f"  hnswlib x86 sweep …")
        build_s, sweep = run_hnswlib_x86(docs, queries, gt, EF_SWEEP)
        x86_report["per_n"][str(n)] = {
            "build_seconds": build_s,
            "sweep": sweep,
        }
        for row in sweep:
            print(f"    ef={row['ef']:>3d}  recall@{K}={row['recall_at_k']:.4f}  "
                  f"p50={row['latency_us']['p50']:>7.1f}µs  "
                  f"p95={row['latency_us']['p95']:>7.1f}µs")

    res = Path(args.results)
    res.parent.mkdir(parents=True, exist_ok=True)
    res.write_text(json.dumps(x86_report, indent=2))
    print(f"\n── wrote {res} ──")


if __name__ == "__main__":
    main()
