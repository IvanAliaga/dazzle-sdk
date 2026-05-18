#!/usr/bin/env python3
"""BGE-small retrieval recall@k on the §5.9 NQ slice.

Reads the cached `passage_embeds.bin` + `query_embeds.bin` +
`queries.json` + `passages.json` produced by
`RagE2EBenchPhases.runEmbedPhase` and computes
`recall@{1,3,5,10}` — the fraction of queries for which a `gold`
passage appears in the top-k by cosine similarity.

Recall is deterministic given the same BGE-small embeddings and
the same NQ slice; cross-platform reproducibility is therefore a
single shared row across all chips that ran the bench. The
script is included for paper reviewers who want to verify the
upper-bound claim in §5.9.5 (Table 19) without the bench harness.

Inputs default to the on-device cache path layout produced by the
multi-process driver. Pass `--cache <dir>` to point at a pulled
copy.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np


def read_float_matrix(path: Path) -> np.ndarray:
    with path.open("rb") as f:
        n = struct.unpack(">i", f.read(4))[0]
        d = struct.unpack(">i", f.read(4))[0]
        data = np.frombuffer(f.read(n * d * 4), dtype=">f4").reshape(n, d).copy()
    return data


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cache", type=Path, default=Path("/tmp"),
                    help="dir holding {passage,query}_embeds.bin + "
                    "queries.json + passages.json")
    ap.add_argument("--prefix", default="kirin_",
                    help="filename prefix when multiple cache snapshots "
                    "live in the same dir (default: 'kirin_')")
    ap.add_argument("--ks", default="1,3,5,10",
                    help="comma-separated k values to score (default 1,3,5,10)")
    args = ap.parse_args(argv)

    pe = read_float_matrix(args.cache / f"{args.prefix}passage_embeds.bin")
    qe = read_float_matrix(args.cache / f"{args.prefix}query_embeds.bin")
    queries = json.load((args.cache / f"{args.prefix}queries.json").open())
    passages = json.load((args.cache / f"{args.prefix}passages.json").open())

    pid_to_row = {p["id"]: i for i, p in enumerate(passages)}

    pe = pe / (np.linalg.norm(pe, axis=1, keepdims=True) + 1e-9)
    qe = qe / (np.linalg.norm(qe, axis=1, keepdims=True) + 1e-9)

    ks = sorted(int(k) for k in args.ks.split(","))
    max_k = max(ks)

    counts = {k: 0 for k in ks}
    total = 0
    for qi, q in enumerate(queries):
        sims = pe @ qe[qi]
        topk = np.argsort(-sims)[:max_k]
        gold_rows = {pid_to_row[g] for g in q["gold"] if g in pid_to_row}
        if not gold_rows:
            continue
        total += 1
        for k in ks:
            if any(t in gold_rows for t in topk[:k]):
                counts[k] += 1

    print(f"# BGE-small recall@k — N passages={pe.shape[0]}, "
          f"dim={pe.shape[1]}, queries={total}/{len(queries)}")
    for k in ks:
        print(f"recall@{k:<3} = {counts[k] / total:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
