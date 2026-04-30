#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Independent audit of the RAG short-answer scoring pipeline.

Validates that ``recompute_rag_metrics.py`` (which mirrors the Kotlin
scorer in ``experiment/backends/android/core/RagE2EBench.kt``) implements
the SQuAD evaluation protocol correctly:

  - normalisation (lower + strip ASCII punctuation + drop articles a/an/the)
  - exact-match on the extracted answer span (em_short)
  - alias-substring match on the full prediction (em_contains)
  - max token-F1 over aliases against the extracted span (f1_short)
  - the SQuAD invariants ``EM_short ≤ F1_short`` and ``EM_short ≤ EM_contains``
    hold per sample, and therefore per average

The fixture file ``research/scripts/fixtures/rag_scoring_cases.json``
is the cross-platform contract — both the Python scorer and the Kotlin
scorer (when run from a unit-test harness on-device) consume the same
inputs and must produce the same outputs.

Run:
    python3 research/scripts/test_rag_scoring.py
or:
    python3 -m unittest research.scripts.test_rag_scoring
"""
from __future__ import annotations

import json
import math
import unittest
from pathlib import Path

# Import the canonical Python implementation that the paper's metrics
# come from. ``recompute_rag_metrics.py`` lives next to this file.
import sys

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from recompute_rag_metrics import (  # noqa: E402
    em_contains,
    em_strict,
    extract_answer_span,
    f1_short,
    normalize,
    token_f1,
)

REPO_ROOT = SCRIPTS_DIR.parent.parent
FIXTURE_PATH = SCRIPTS_DIR / "fixtures" / "rag_scoring_cases.json"


# ── Tier 1: SQuAD-protocol normalisation ──────────────────────────────


class NormalisationTests(unittest.TestCase):
    """Per the SQuAD v1.1 evaluation script (Rajpurkar et al. 2016, §3.1
    of arxiv:1606.05250 + the official evaluate-v1.1.py): normalisation
    must (a) lowercase, (b) remove ASCII punctuation, (c) drop the
    English articles a/an/the, (d) collapse internal whitespace."""

    def test_lowercase(self):
        self.assertEqual(normalize("PARIS"), ["paris"])
        self.assertEqual(normalize("Paris"), ["paris"])

    def test_drops_articles(self):
        self.assertEqual(normalize("the Eiffel Tower"), ["eiffel", "tower"])
        self.assertEqual(normalize("A red rose"), ["red", "rose"])
        self.assertEqual(normalize("an apple"), ["apple"])
        self.assertEqual(normalize("a, an, the"), [])

    def test_strips_punctuation(self):
        self.assertEqual(normalize("Paris."), ["paris"])
        self.assertEqual(normalize("Paris!?"), ["paris"])
        self.assertEqual(normalize("Mark, Skaife."), ["mark", "skaife"])
        self.assertEqual(normalize("(Paris)"), ["paris"])

    def test_collapses_whitespace(self):
        self.assertEqual(normalize("Mark    Skaife"), ["mark", "skaife"])
        self.assertEqual(normalize("Mark\tSkaife"), ["mark", "skaife"])
        self.assertEqual(normalize("Mark \n Skaife"), ["mark", "skaife"])

    def test_empty_input(self):
        self.assertEqual(normalize(""), [])
        self.assertEqual(normalize("   "), [])
        self.assertEqual(normalize("the the the"), [])


# ── Tier 2: span extraction ───────────────────────────────────────────


class SpanExtractionTests(unittest.TestCase):
    """The model is prompted with `Question: … Answer:`; the generated
    text starts with the actual answer and may then hallucinate a fresh
    `Question:` or `Answer:` continuation. We cut at the first newline
    or fresh delimiter."""

    def test_cut_at_newline(self):
        self.assertEqual(extract_answer_span(" Paris\nmore stuff"), "Paris")

    def test_cut_at_question_marker(self):
        self.assertEqual(extract_answer_span(" foo Question: bar"), "foo")

    def test_cut_at_fresh_answer_marker(self):
        # Model hallucinates a second Q/A pair. We keep only the first answer.
        self.assertEqual(
            extract_answer_span(" Mark. Answer: Mark. Answer: Mark."),
            "Mark.",
        )

    def test_strip_leading_whitespace(self):
        self.assertEqual(extract_answer_span("    Paris"), "Paris")

    def test_empty_or_whitespace_only(self):
        self.assertEqual(extract_answer_span("   "), "")
        self.assertEqual(extract_answer_span(""), "")

    def test_no_terminator_returns_trimmed(self):
        # No newline / Question: / Answer: in body; full string survives.
        self.assertEqual(extract_answer_span(" Paris is the capital "), "Paris is the capital")


# ── Tier 3: EM_short (strict, on extracted span) ──────────────────────


class EmShortTests(unittest.TestCase):
    """`em_strict(span, aliases)` should be 1.0 iff the normalised span
    equals at least one normalised alias exactly. SQuAD-equivalent."""

    def test_exact_match_after_normalisation(self):
        self.assertEqual(em_strict("Paris", ["Paris"]), 1.0)
        self.assertEqual(em_strict("paris.", ["Paris"]), 1.0)  # punct + case
        self.assertEqual(em_strict("the eiffel tower", ["Eiffel Tower"]), 1.0)

    def test_substring_does_not_count(self):
        # Strict EM rejects "Paris is the capital" against alias "Paris".
        self.assertEqual(em_strict("Paris is the capital", ["Paris"]), 0.0)

    def test_multi_alias_matches_any(self):
        self.assertEqual(em_strict("New York", ["New York City", "New York"]), 1.0)
        self.assertEqual(em_strict("NYC", ["New York City", "New York"]), 0.0)

    def test_empty_aliases_returns_none(self):
        # Used by the harness to skip examples without gold answers.
        self.assertIsNone(em_strict("Paris", []))

    def test_empty_alias_skipped(self):
        # Single empty-string alias should not match an empty span as 1.0;
        # both sides normalise to [] and the implementation treats `[] == []`
        # as a non-match (alias is required to have content). This matches
        # the Kotlin scorer's behaviour.
        self.assertEqual(em_strict("", [""]), 0.0)


# ── Tier 4: EM_contains (lax, on full prediction) ─────────────────────


class EmContainsTests(unittest.TestCase):
    """Substring match: any alias's normalised tokens appear contiguously
    in the full prediction. Useful for verbose generations where the
    correct answer is embedded in surrounding text."""

    def test_substring_match_in_verbose_reply(self):
        self.assertEqual(em_contains("The answer is Paris.", ["Paris"]), 1.0)
        self.assertEqual(em_contains("Paris is the capital of France", ["Paris"]), 1.0)

    def test_no_substring_match(self):
        self.assertEqual(em_contains("Aladdin", ["Paris"]), 0.0)
        self.assertEqual(em_contains("", ["Paris"]), 0.0)

    def test_alias_longer_than_pred_skipped(self):
        # `g.size > p.size` short-circuits in both implementations.
        self.assertEqual(em_contains("Paris", ["The City of Paris in France"]), 0.0)

    def test_multi_token_substring(self):
        self.assertEqual(
            em_contains("she lives in New York City",
                        ["New York City"]),
            1.0,
        )

    def test_articles_dropped_before_match(self):
        # "the" is dropped, so "in the New York City area" should still match
        # the alias "New York City" despite the article in between.
        self.assertEqual(
            em_contains("in the New York City area", ["New York City"]),
            1.0,
        )


# ── Tier 5: F1_short (max token-F1 over aliases against the span) ─────


class F1ShortTests(unittest.TestCase):
    """SQuAD-protocol token F1: bag-of-tokens overlap between prediction
    and gold, reported as max over aliases."""

    def test_identical_strings_score_one(self):
        self.assertEqual(token_f1("Paris", "Paris"), 1.0)
        self.assertEqual(f1_short("Paris", ["Paris"]), 1.0)

    def test_disjoint_strings_score_zero(self):
        self.assertEqual(token_f1("Aladdin", "Paris"), 0.0)
        self.assertEqual(f1_short("Aladdin", ["Paris"]), 0.0)

    def test_partial_overlap_two_of_three(self):
        # pred = {mark, skaife, won}, gold = {mark, skaife}
        # overlap = 2; precision = 2/3, recall = 2/2 = 1.0
        # F1 = 2*(2/3)*1 / (2/3 + 1) = (4/3) / (5/3) = 4/5 = 0.8
        self.assertAlmostEqual(token_f1("Mark Skaife won", "Mark Skaife"), 0.8, places=6)

    def test_max_over_aliases(self):
        # Best-matching alias should win; verifies the harness
        # picks the maximum, not the first or the average.
        f1 = f1_short("Mark Skaife", ["Aladdin", "Mark Skaife", "Eiffel Tower"])
        self.assertEqual(f1, 1.0)

    def test_partial_year_match(self):
        # Classic SQuAD edge case: numeric span partially matches a longer
        # date alias. Tokens are ["1957"] vs ["1", "april", "1957"];
        # overlap = 1; precision = 1/1 = 1, recall = 1/3
        # F1 = 2 * 1 * (1/3) / (1 + 1/3) = (2/3) / (4/3) = 0.5
        self.assertAlmostEqual(token_f1("1957", "1 April 1957"), 0.5, places=6)


# ── Tier 6: SQuAD invariants ──────────────────────────────────────────


class InvariantTests(unittest.TestCase):
    """The two structural invariants the paper claims hold: per sample
    (and therefore per average), ``EM_short ≤ F1_short`` and
    ``EM_short ≤ EM_contains``. The first is a SQuAD identity (when EM=1
    the bags are equal so F1=1). The second follows from the fact that
    span equality implies span-as-substring."""

    INVARIANT_CASES = [
        # (prediction, aliases) — all must satisfy EM ≤ F1 and EM ≤ contains
        (" Mark Skaife won the championship.", ["Mark Skaife"]),
        (" 1957", ["1 April 1957"]),
        (" The Little Mermaid.", ["Aladdin"]),
        (" 1776", ["1776"]),
        (" Paris\nQuestion: foo", ["Paris"]),
        (" Paris", ["Paris"]),
        (" the answer is Paris", ["Paris"]),
        (" New York City", ["New York", "New York City"]),
        ("", ["Paris"]),
        (" Aladdin Aladdin Aladdin", ["Aladdin"]),
    ]

    def test_em_short_le_f1_short(self):
        for ans, aliases in self.INVARIANT_CASES:
            with self.subTest(ans=ans, aliases=aliases):
                span = extract_answer_span(ans)
                em = em_strict(span, aliases) or 0.0
                f1 = f1_short(span, aliases) or 0.0
                self.assertLessEqual(em, f1 + 1e-9, f"EM={em} > F1={f1} for {ans!r}")

    def test_em_short_le_em_contains(self):
        for ans, aliases in self.INVARIANT_CASES:
            with self.subTest(ans=ans, aliases=aliases):
                span = extract_answer_span(ans)
                em = em_strict(span, aliases) or 0.0
                ct = em_contains(ans, aliases) or 0.0
                self.assertLessEqual(em, ct + 1e-9, f"EM={em} > contains={ct} for {ans!r}")


# ── Tier 7: cross-platform fixture parity ─────────────────────────────


class FixtureParityTests(unittest.TestCase):
    """Validates the canonical fixture at
    ``research/scripts/fixtures/rag_scoring_cases.json``. The same
    fixture is consumed by the on-device Kotlin scorer test (when
    invoked from the experiment harness) so both implementations must
    agree on every case. Any drift here is a parity bug."""

    @classmethod
    def setUpClass(cls):
        if not FIXTURE_PATH.exists():
            raise unittest.SkipTest(f"fixture missing: {FIXTURE_PATH}")
        with FIXTURE_PATH.open() as f:
            cls.fixture = json.load(f)

    def test_fixture_has_minimum_cases(self):
        cases = self.fixture["cases"]
        self.assertGreaterEqual(len(cases), 16, "fixture must carry ≥16 cases for the audit")

    def test_every_case_matches_python_scorer(self):
        for i, case in enumerate(self.fixture["cases"]):
            with self.subTest(i=i, name=case["name"]):
                ans = case["prediction"]
                aliases = case["aliases"]
                span = extract_answer_span(ans)
                got_em = em_strict(span, aliases)
                got_ct = em_contains(ans, aliases)
                got_f1 = f1_short(span, aliases)
                exp_em = case["expect"]["em_short"]
                exp_ct = case["expect"]["em_contains"]
                exp_f1 = case["expect"]["f1_short"]

                def _eq(a, b):
                    if a is None or b is None:
                        return a == b
                    return math.isclose(a, b, abs_tol=1e-6)

                self.assertTrue(_eq(got_em, exp_em),
                                f"em_short: got {got_em} expected {exp_em}")
                self.assertTrue(_eq(got_ct, exp_ct),
                                f"em_contains: got {got_ct} expected {exp_ct}")
                self.assertTrue(_eq(got_f1, exp_f1),
                                f"f1_short: got {got_f1} expected {exp_f1}")


# ── Tier 8: regression on cited paper run ─────────────────────────────


class CitedRunRegressionTests(unittest.TestCase):
    """Re-score the per-query examples in the JSON cited by Table 15 and
    verify the aggregates match the paper's reported numbers within
    rounding tolerance. Catches any future drift between the on-device
    bench and this offline scorer (which would invalidate every paper
    cell that depends on the fix)."""

    JSON_PATH = (
        REPO_ROOT
        / "research"
        / "benchmarks"
        / "results"
        / "Moto_G35_5G"
        / "rag_2x2"
        / "rag_e2e_moto_g35_5G_1777395311213.json"
    )

    PAPER_T15 = {
        # variant -> (em_short, em_contains, f1_short, f1_passage) per Table 15
        "small_no_rag":  (0.015, 0.105, 0.079, 0.151),
        "small_rag":     (0.120, 0.630, 0.235, 0.334),
        "large_no_rag":  (0.045, 0.110, 0.118, 0.085),
        "large_rag":     (0.310, 0.735, 0.487, 0.235),
    }

    @classmethod
    def setUpClass(cls):
        if not cls.JSON_PATH.exists():
            raise unittest.SkipTest(f"cited run JSON not present: {cls.JSON_PATH}")
        with cls.JSON_PATH.open() as f:
            cls.data = json.load(f)

    def test_paper_t15_matches_rescore(self):
        from recompute_rag_metrics import rescore_records  # noqa: WPS433
        for vname, (em_p, ct_p, f1_p, f1pass_p) in self.PAPER_T15.items():
            with self.subTest(variant=vname):
                examples = self.data["variants"][vname]["examples"]
                rescored = rescore_records(examples)
                # the table is rounded to 3 dec places; allow ±0.005 on each.
                self.assertAlmostEqual(rescored["em_short"], em_p, delta=0.005,
                                        msg=f"{vname} em_short drift")
                self.assertAlmostEqual(rescored["em_contains"], ct_p, delta=0.005,
                                        msg=f"{vname} em_contains drift")
                self.assertAlmostEqual(rescored["f1_short"], f1_p, delta=0.005,
                                        msg=f"{vname} f1_short drift")


# ── entry point ───────────────────────────────────────────────────────


def main() -> int:
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
