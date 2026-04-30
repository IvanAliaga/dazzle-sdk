#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""
Build a deterministic mini-slice of Natural Questions for the on-device RAG
recall bench (E2).

Source: `sentence-transformers/natural-questions` (HuggingFace) — a paired
(question, positive_passage) version of NQ where each row supplies one gold
passage per question. We use it instead of BEIR-NQ to keep the download in
the hundreds of MB rather than gigabytes, while preserving the standard NQ
semantics (Wikipedia passages, open-domain questions).

Output (committed under experiment/backends/android/assets/nq_slice/):

    passages.jsonl   2000 lines of {"_id", "text"}
    queries.jsonl     200 lines of {"_id", "text", "gold"}
    README.md         provenance + seed + counts

Deterministic under --seed (default 42). Re-running produces an identical
slice, modulo the raw upstream file.

Usage:
    python3 research/scripts/nq_slice.py
    python3 research/scripts/nq_slice.py --n-queries 400 --n-passages 5000
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import urllib.request
from pathlib import Path

import pyarrow.parquet as pq  # noqa: E402

REPO_ROOT     = Path(__file__).resolve().parents[2]
ASSETS_DIR    = REPO_ROOT / "experiment" / "backends" / "android" / "assets" / "nq_slice"
CACHE_DIR     = REPO_ROOT / "research" / "data" / "nq_slice" / "raw"
README_PATH   = REPO_ROOT / "research" / "data" / "nq_slice" / "README.md"

# Pair split of the SBERT-bundled NQ: ~100k (anchor, positive) rows, parquet.
RAW_URL  = "https://huggingface.co/datasets/sentence-transformers/natural-questions/resolve/main/pair/train-00000-of-00001.parquet"
RAW_NAME = "nq_pair_train.parquet"

# NQ-open provides the canonical short answers for each NQ question (lists
# of strings — aliases). We join by question text to attach them to the
# pair-split rows so the on-device bench can evaluate EM / F1 against real
# short answers instead of the full gold passage.
NQO_TRAIN_URL = "https://huggingface.co/datasets/google-research-datasets/nq_open/resolve/main/nq_open/train-00000-of-00001.parquet"
NQO_VAL_URL   = "https://huggingface.co/datasets/google-research-datasets/nq_open/resolve/main/nq_open/validation-00000-of-00001.parquet"
NQO_TRAIN_NAME = "nq_open_train.parquet"
NQO_VAL_NAME   = "nq_open_val.parquet"


def download(url: str, dest: Path) -> None:
    """Download `url` to `dest` if not already present. Streams — no full
    buffer in memory for large files."""
    if dest.exists() and dest.stat().st_size > 0:
        print(f"[cache] {dest.name} already present ({dest.stat().st_size:,} bytes)", file=sys.stderr)
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"[fetch] {url}", file=sys.stderr)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as resp, open(tmp, "wb") as out:
        total  = int(resp.headers.get("Content-Length") or 0)
        pulled = 0
        chunk  = 1 << 20  # 1 MiB
        while True:
            buf = resp.read(chunk)
            if not buf:
                break
            out.write(buf)
            pulled += len(buf)
            if total:
                pct = pulled * 100 // total
                print(f"\r  {pulled / 1e6:6.1f} MB / {total / 1e6:6.1f} MB  ({pct}%)",
                      end="", file=sys.stderr)
        print("", file=sys.stderr)
    tmp.rename(dest)


def load_pairs(path: Path):
    """Yield (question, passage) pairs from the parquet file. SBERT pair
    format has columns `anchor` (question) and `positive` (passage)."""
    table = pq.read_table(path)
    cols  = {c: table.column(c) for c in table.schema.names}
    # Accept a handful of naming variants so the script still works if the
    # upstream dataset renames columns in a future release.
    q_col = cols.get("anchor") or cols.get("question") or cols.get("query")
    p_col = (cols.get("positive") or cols.get("passage")
             or cols.get("text") or cols.get("answer"))
    if q_col is None or p_col is None:
        raise RuntimeError(f"parquet is missing anchor/positive columns; "
                           f"got {list(cols.keys())}")
    for q, p in zip(q_col.to_pylist(), p_col.to_pylist()):
        if isinstance(q, str) and isinstance(p, str) and q.strip() and p.strip():
            yield q.strip(), p.strip()


def load_short_answers(paths: list[Path]) -> dict[str, list[str]]:
    """Build a lookup: normalised_question → list[str] of short answers.

    NQ-open's `answer` column is a list of alias strings. We key on the
    lowercased, trimmed question text (the pair split uses the same
    normalisation upstream, so an exact match on that key is reliable)."""
    lookup: dict[str, list[str]] = {}
    for path in paths:
        if not path.exists():
            continue
        table = pq.read_table(path)
        for q, a in zip(table.column("question").to_pylist(),
                        table.column("answer").to_pylist()):
            if not isinstance(q, str) or a is None:
                continue
            key = q.strip().lower()
            # Some answers come as list<string>, others as a single string —
            # accept both defensively.
            answers = a if isinstance(a, list) else [a]
            answers = [s.strip() for s in answers if isinstance(s, str) and s.strip()]
            if answers:
                lookup[key] = answers
    return lookup


def truncate_chars(s: str, max_chars: int) -> str:
    """Clamp a passage to `max_chars`, preferring to break at a space so the
    truncated suffix isn't a mid-word fragment that would mislead the embedder."""
    if len(s) <= max_chars:
        return s
    cut = s[:max_chars]
    sp  = cut.rfind(" ")
    return cut if sp <= 0 else cut[:sp]


def stable_id(prefix: str, idx: int) -> str:
    return f"{prefix}_{idx:05d}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed",        type=int, default=42)
    ap.add_argument("--n-queries",   type=int, default=200)
    ap.add_argument("--n-passages",  type=int, default=2000)
    ap.add_argument("--max-passage-chars", type=int, default=1800,
                    help="Per-passage character cap — keeps embedding within "
                         "bge-small's 512-token context (≈2048 chars).")
    ap.add_argument("--max-query-chars",   type=int, default=256)
    args = ap.parse_args()

    if args.n_queries > args.n_passages:
        ap.error("n-passages must be ≥ n-queries (each query needs its gold passage in the corpus)")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    README_PATH.parent.mkdir(parents=True, exist_ok=True)

    raw_path = CACHE_DIR / RAW_NAME
    download(RAW_URL, raw_path)

    nqo_train = CACHE_DIR / NQO_TRAIN_NAME
    nqo_val   = CACHE_DIR / NQO_VAL_NAME
    download(NQO_TRAIN_URL, nqo_train)
    download(NQO_VAL_URL,   nqo_val)
    short_answers = load_short_answers([nqo_train, nqo_val])
    print(f"[parse] nq_open lookup: {len(short_answers):,} question→answers",
          file=sys.stderr)

    # First pass: deduplicate passages. SBERT's pair dump repeats passages
    # across queries sometimes — we want a clean passage-id space, so a
    # passage appears once even if several questions point at it.
    print("[parse] streaming pairs…", file=sys.stderr)
    pair_rows   = []
    passage_ids = {}          # passage_text → pid
    for q, p in load_pairs(raw_path):
        q_trunc = truncate_chars(q, args.max_query_chars)
        p_trunc = truncate_chars(p, args.max_passage_chars)
        if p_trunc not in passage_ids:
            passage_ids[p_trunc] = stable_id("p", len(passage_ids) + 1)
        pair_rows.append((q_trunc, passage_ids[p_trunc], p_trunc))

    print(f"[parse] {len(pair_rows):,} pairs, {len(passage_ids):,} unique passages",
          file=sys.stderr)

    # Deterministic shuffle → pick queries, then pad with distractor passages.
    # Prefer questions that have a short answer in nq_open; this guarantees
    # the EM/F1 evaluator has a gold to score against. We fall back to
    # questions without short answers only if we can't find enough.
    rng = random.Random(args.seed)
    idxs = list(range(len(pair_rows)))
    rng.shuffle(idxs)

    chosen_queries  = []
    chosen_texts    = set()
    gold_pids       = set()
    with_answer     = 0
    for require_ans in (True, False):
        if len(chosen_queries) >= args.n_queries:
            break
        for i in idxs:
            q, pid, _ = pair_rows[i]
            if q in chosen_texts:
                continue
            answers = short_answers.get(q.lower())
            if require_ans and not answers:
                continue
            entry: dict = {
                "_id":  stable_id("q", len(chosen_queries) + 1),
                "text": q,
                "gold": [pid],
            }
            if answers:
                entry["short_answers"] = answers
                with_answer += 1
            chosen_queries.append(entry)
            chosen_texts.add(q)
            gold_pids.add(pid)
            if len(chosen_queries) >= args.n_queries:
                break

    if len(chosen_queries) < args.n_queries:
        print(f"warning: only found {len(chosen_queries)} unique queries "
              f"(requested {args.n_queries})", file=sys.stderr)
    print(f"[parse] queries with short_answers: {with_answer}/{len(chosen_queries)}",
          file=sys.stderr)

    # Build the passage corpus: every gold passage + random distractors until
    # we reach n_passages. Distractors come from the global pool, not just
    # the chosen queries.
    all_pids   = list(passage_ids.values())
    text_by_id = {pid: text for text, pid in passage_ids.items()}
    rng.shuffle(all_pids)

    corpus_pids = list(gold_pids)
    for pid in all_pids:
        if len(corpus_pids) >= args.n_passages:
            break
        if pid in gold_pids:
            continue
        corpus_pids.append(pid)
    corpus_pids = corpus_pids[:args.n_passages]

    # Shuffle the final corpus order so gold passages don't all sit at the top
    # — otherwise a broken bench that returns ids in insertion order looks
    # like it's working.
    rng.shuffle(corpus_pids)

    # ── Write slice ─────────────────────────────────────────────────────
    passages_path = ASSETS_DIR / "passages.jsonl"
    queries_path  = ASSETS_DIR / "queries.jsonl"
    with open(passages_path, "w", encoding="utf-8") as f:
        for pid in corpus_pids:
            f.write(json.dumps({"_id": pid, "text": text_by_id[pid]},
                               ensure_ascii=False) + "\n")
    with open(queries_path, "w", encoding="utf-8") as f:
        for q in chosen_queries:
            f.write(json.dumps(q, ensure_ascii=False) + "\n")

    # ── Hash for provenance ─────────────────────────────────────────────
    h = hashlib.sha256()
    for p in (passages_path, queries_path):
        h.update(p.read_bytes())
    digest = h.hexdigest()[:16]

    README_PATH.write_text(
        "# NQ-open retrieval mini-slice (E2 / E3)\n\n"
        "Materialised from `sentence-transformers/natural-questions` (pair\n"
        "split, for passages) + `google-research-datasets/nq_open` (for\n"
        "canonical short answers, joined by question text).\n\n"
        f"- passage source:   `{RAW_URL}`\n"
        f"- answer source:    `{NQO_TRAIN_URL}` +\n"
        f"                    `{NQO_VAL_URL}`\n"
        f"- seed:             `{args.seed}`\n"
        f"- queries:          `{len(chosen_queries)}`  "
        f"(`{with_answer}` with short_answers attached)\n"
        f"- passages:         `{len(corpus_pids)}`\n"
        f"- gold/queries:     `1` (one positive passage per query)\n"
        f"- max_query_chars:   `{args.max_query_chars}`\n"
        f"- max_passage_chars: `{args.max_passage_chars}`\n"
        f"- sha256 (first 16):  `{digest}`\n\n"
        "Each query JSON row has `_id`, `text`, `gold` (list of passage ids),\n"
        "and optionally `short_answers` (list of alias strings from nq_open).\n"
        "Queries without a short_answers field have no canonical answer in\n"
        "nq_open; EM / F1 scoring should skip them.\n\n"
        "Regenerate:\n\n"
        "```\n"
        "python3 research/scripts/nq_slice.py\n"
        "```\n",
        encoding="utf-8",
    )

    print(f"[write] {passages_path.relative_to(REPO_ROOT)}  "
          f"({passages_path.stat().st_size:,} bytes)", file=sys.stderr)
    print(f"[write] {queries_path.relative_to(REPO_ROOT)}  "
          f"({queries_path.stat().st_size:,} bytes)", file=sys.stderr)
    print(f"[write] {README_PATH.relative_to(REPO_ROOT)}", file=sys.stderr)
    print(f"[done]  n_queries={len(chosen_queries)}  n_passages={len(corpus_pids)}  "
          f"digest={digest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
