#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Recompute short-answer metrics for an RagE2EBench JSON.

Mirrors the Kotlin scoring in ``RagE2EBench.kt`` (SQuAD/NQ-open style):
extracts the answer span, then reports three short-answer metrics plus a
passage backup. Use either to verify a stale run offline (only the
records persisted in ``examples`` can be rescored) or to reprocess a
fresh run that ships with the full per-query log.

Usage:
    python recompute_rag_metrics.py PATH_TO_RAG_E2E.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unittest
from collections import Counter
from pathlib import Path
from typing import Iterable, Sequence

# ── Scoring primitives (must match RagE2EBench.kt) ──────────────────────

STOP = {"a", "an", "the"}
_PUNCT = re.compile(r"[^\w\s]+", re.UNICODE)
_WS = re.compile(r"\s+")


def normalize(s: str) -> list[str]:
    """SQuAD-style normalisation: lower + strip punct + drop articles."""
    flat = _PUNCT.sub(" ", s.lower())
    return [t for t in _WS.split(flat) if t and t not in STOP]


def extract_answer_span(raw: str) -> str:
    """Cut at first newline / fresh ``Question:`` / fresh ``Answer:``.

    The prompt already ends in ``Answer:`` so a second occurrence in the
    generation is a hallucinated continuation we discard.
    """
    s = raw.lstrip()
    cut = len(s)
    for token in ("\n", "Question:", "Answer:"):
        i = s.find(token)
        if 0 <= i < cut:
            cut = i
    return s[:cut].strip()


def _token_f1(p: Sequence[str], g: Sequence[str]) -> float:
    if not p or not g:
        return 0.0
    pc = Counter(p)
    overlap = 0
    for t in g:
        if pc[t] > 0:
            overlap += 1
            pc[t] -= 1
    if overlap == 0:
        return 0.0
    precision = overlap / len(p)
    recall = overlap / len(g)
    return 2 * precision * recall / (precision + recall)


def token_f1(pred: str, gold: str) -> float:
    return _token_f1(normalize(pred), normalize(gold))


def em_strict(span: str, aliases: Iterable[str]) -> float | None:
    aliases = list(aliases)
    if not aliases:
        return None
    p = normalize(span)
    for a in aliases:
        g = normalize(a)
        if g and p == g:
            return 1.0
    return 0.0


def em_contains(pred: str, aliases: Iterable[str]) -> float | None:
    aliases = list(aliases)
    if not aliases:
        return None
    p = normalize(pred)
    if not p:
        return 0.0
    for a in aliases:
        g = normalize(a)
        if not g or len(g) > len(p):
            continue
        for i in range(len(p) - len(g) + 1):
            if p[i : i + len(g)] == g:
                return 1.0
    return 0.0


def f1_short(span: str, aliases: Iterable[str]) -> float | None:
    aliases = list(aliases)
    if not aliases:
        return None
    p = normalize(span)
    return max((_token_f1(p, normalize(a)) for a in aliases), default=0.0)


# ── Aggregation helpers ────────────────────────────────────────────────


def _avg(xs: list[float]) -> float | None:
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def rescore_records(records: list[dict]) -> dict:
    """Rescore the per-query records and return aggregate stats."""
    rescored = []
    for r in records:
        ans = r.get("answer", "") or ""
        aliases = r.get("short_answers") or []
        span = extract_answer_span(ans)
        rescored.append(
            {
                "qid": r.get("qid"),
                "answer": ans,
                "answer_span": span,
                "short_answers": aliases,
                "em_short": em_strict(span, aliases),
                "em_contains": em_contains(ans, aliases),
                "f1_short": f1_short(span, aliases),
            }
        )

    n = len(rescored)
    em = _avg([r["em_short"] for r in rescored])
    ct = _avg([r["em_contains"] for r in rescored])
    f1 = _avg([r["f1_short"] for r in rescored])

    return {
        "n": n,
        "em_short": em,
        "em_contains": ct,
        "f1_short": f1,
        "records": rescored,
    }


# ── CLI ────────────────────────────────────────────────────────────────


def _fmt(x: float | None) -> str:
    return "—" if x is None else f"{x:.3f}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=Path, help="rag_e2e_*.json file")
    ap.add_argument(
        "--show",
        type=int,
        default=10,
        help="how many per-record diffs to print (default 10)",
    )
    args = ap.parse_args(argv)

    with args.path.open() as f:
        d = json.load(f)

    print(f"file: {args.path}")
    print(f"slice: {d.get('slice', {})}")
    print(f"config: {d.get('config', {})}")
    print()

    for vname, vdata in d.get("variants", {}).items():
        records = vdata.get("examples", [])
        old = {
            "em_short": (vdata.get("em_short") or {}).get("avg"),
            "f1_short": (vdata.get("f1_short") or {}).get("avg"),
            "em_contains": (vdata.get("em_contains") or {}).get("avg"),
            "n_reported": (vdata.get("em_short") or {}).get("n"),
        }
        rescored = rescore_records(records)

        print(f"== {vname} ==")
        print(f"  reported (over n={old['n_reported']}):")
        print(
            f"    em_short(old=substring) = {_fmt(old['em_short'])}    "
            f"f1_short(old=full output)   = {_fmt(old['f1_short'])}"
        )
        print(f"  recomputed on stored examples (n={rescored['n']}):")
        print(
            f"    em_short(strict, span)  = {_fmt(rescored['em_short'])}    "
            f"f1_short(span)              = {_fmt(rescored['f1_short'])}    "
            f"em_contains(full)          = {_fmt(rescored['em_contains'])}"
        )
        em, f1, ct = (
            rescored["em_short"],
            rescored["f1_short"],
            rescored["em_contains"],
        )
        if em is not None and f1 is not None and ct is not None:
            inv = (em <= f1 + 1e-9) and (em <= ct + 1e-9)
            print(
                f"  invariant em_short ≤ f1_short and em_short ≤ em_contains: "
                f"{'OK' if inv else 'VIOLATED'} "
                f"(em={em:.3f}, f1={f1:.3f}, ct={ct:.3f})"
            )
        print()
        for r in rescored["records"][: args.show]:
            ans = r["answer"]
            ans = ans if len(ans) <= 120 else ans[:117] + "..."
            print(
                f"  {r['qid']}  alias={r['short_answers']}  "
                f"em={_fmt(r['em_short'])} ct={_fmt(r['em_contains'])} "
                f"f1={_fmt(r['f1_short'])}"
            )
            print(f"    span : {r['answer_span']!r}")
            print(f"    raw  : {ans!r}")
        print()

    return 0


# ── Self-tests ─────────────────────────────────────────────────────────


class _SelfTest(unittest.TestCase):
    def test_paris_canonical(self):
        # Paris example from the §5.9.1 regression check.
        ans = "The answer is Paris."
        self.assertEqual(em_strict(extract_answer_span(ans), ["Paris"]), 0.0)
        # F1 captures the partial match, contains is the lax positive signal.
        self.assertGreater(f1_short(extract_answer_span(ans), ["Paris"]), 0.0)
        self.assertEqual(em_contains(ans, ["Paris"]), 1.0)

        # Strict EM only fires when the span itself equals an alias.
        self.assertEqual(em_strict(extract_answer_span(" Paris\nfoo"), ["Paris"]), 1.0)
        self.assertEqual(f1_short(extract_answer_span(" Paris"), ["Paris"]), 1.0)

    def test_invariant_holds(self):
        # em_short ≤ f1_short and em_short ≤ em_contains by construction.
        # f1_short and em_contains are NOT nested: a short span can have
        # partial-token overlap with a long alias (f1>0) yet fail the
        # contiguous-substring test (em_contains=0), e.g. "1957" vs
        # "1 April 1957".
        cases = [
            (" Mark Skaife won the championship.", ["Mark Skaife"]),
            (" 1957", ["1 April 1957"]),
            (" The Little Mermaid.", ["Aladdin"]),
            (" 1776", ["1776"]),
            (" Paris\nQuestion: foo", ["Paris"]),
        ]
        for ans, aliases in cases:
            span = extract_answer_span(ans)
            em = em_strict(span, aliases) or 0.0
            f1 = f1_short(span, aliases) or 0.0
            ct = em_contains(ans, aliases) or 0.0
            self.assertLessEqual(em, f1 + 1e-9, f"em>{f1} for {ans!r}")
            self.assertLessEqual(em, ct + 1e-9, f"em>{ct} for {ans!r}")

    def test_extract_cuts(self):
        self.assertEqual(extract_answer_span(" Paris\nmore"), "Paris")
        self.assertEqual(
            extract_answer_span(" Mark. Answer: Mark. Answer: Mark."),
            "Mark.",
        )
        self.assertEqual(extract_answer_span(" foo Question: bar"), "foo")
        self.assertEqual(extract_answer_span("   "), "")

    def test_normalize_drops_articles(self):
        self.assertEqual(normalize("The Eiffel Tower"), ["eiffel", "tower"])
        self.assertEqual(normalize("a, an, the"), [])


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        unittest.main(argv=sys.argv[:1] + sys.argv[2:], exit=False)
    else:
        sys.exit(main())
