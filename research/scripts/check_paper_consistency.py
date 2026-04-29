#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# check_paper_consistency.py — flag drift between the paper and the
# raw bench JSONs.
#
# Each entry in PAPER_CHECKS is a single quantitative claim made in
# `research/paper/paper_v2_en.md`. The script:
#   1. greps the paper for the claim's anchor string and asserts the
#      asserted value still appears verbatim. Anchors are lifted from
#      the markdown (not the LaTeX) because the markdown is the
#      source of truth — the LaTeX `body.tex` is generated.
#   2. opens the corresponding raw JSON (or pair of JSONs) under
#      `research/benchmarks/results/...`, recomputes the claim from
#      the raw fields (median / p50 / mean as the paper specifies),
#      and compares against the asserted value with a tolerance.
#   3. prints `OK` / `DRIFT` per check and exits non-zero on any
#      drift, so this script can be wired into CI before tagging a
#      paper revision.
#
# It is **not** a regenerator — it does not write to the paper.
# Drift is escalated to the human author, who decides whether to
# (a) update the paper, (b) re-run the bench, or (c) flag the
# claim as approximate with a $\pm$ tolerance in the paper itself.
#
# Usage:
#   python3 research/scripts/check_paper_consistency.py
#   python3 research/scripts/check_paper_consistency.py --verbose
#   python3 research/scripts/check_paper_consistency.py --only T3,T11

import argparse
import glob
import json
import math
import re
import statistics
import sys
from pathlib import Path
from typing import Any, Callable, Optional

REPO = Path(__file__).resolve().parents[2]
PAPER = REPO / "research" / "paper" / "paper_v2_en.md"
RESULTS = REPO / "research" / "benchmarks" / "results"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_paper() -> str:
    return PAPER.read_text(encoding="utf-8")


def assert_in_paper(paper: str, anchor: str) -> bool:
    """Strict containment: the anchor (with internal whitespace
    collapsed) must appear in the paper as-is. Uses a regex so we
    can write claims with `\\s+` between tokens."""
    pattern = re.compile(anchor, re.DOTALL)
    return bool(pattern.search(paper))


def median_of(jsons: list[dict], key_path: list[str]) -> Optional[float]:
    """Walk `key_path` into each json and return the median of values
    that are numeric and non-negative."""
    values: list[float] = []
    for d in jsons:
        cur: Any = d
        for k in key_path:
            if not isinstance(cur, dict) or k not in cur:
                cur = None
                break
            cur = cur[k]
        if isinstance(cur, (int, float)) and cur is not None and cur >= 0:
            values.append(float(cur))
    if not values:
        return None
    return statistics.median(values)


def load_jsons(glob_pattern: str) -> list[dict]:
    paths = sorted(RESULTS.glob(glob_pattern))
    out = []
    for p in paths:
        try:
            out.append(json.loads(p.read_text(encoding="utf-8")))
        except json.JSONDecodeError:
            continue
    return out


def best_ef(entry: dict, floor: float = 0.95) -> Optional[dict]:
    """Operating-point selection used in §5.8: lowest p50 search
    latency among ef values that meet the recall floor; fall back to
    the highest-recall ef if none meets the floor."""
    by_ef = entry.get("by_ef")
    if not by_ef:
        return None
    above = [e for e in by_ef if e.get("recall_at_k", 0) >= floor]
    if above:
        return min(above, key=lambda e: e["search_lat_us"]["p50"])
    return max(by_ef, key=lambda e: e.get("recall_at_k", 0))


# ---------------------------------------------------------------------------
# Each check is a self-contained function returning (ok, msg).
# ---------------------------------------------------------------------------

def check_t3_objectbox_iphone(paper: str, tol_pct: float = 5.0) -> tuple[bool, str]:
    """Table 3 — ObjectBox iPhone ingest 4 840 / retrieval 638 µs."""
    paper_anchor = r"ObjectBox \$\\ddagger\$.*?\|\s*1 839 / 778\s*\|\s*4 840 / 638\s*\|"
    if not assert_in_paper(paper, paper_anchor):
        return False, "T3 ObjectBox iPhone row not found verbatim (4 840 / 638)"
    files = load_jsons("iPhone_12_Pro/objectbox/storageonly_objectbox_177737*.json")
    if len(files) < 3:
        return False, f"Need 3 post-fix runs; found {len(files)} (timestamps starting 177737*)"
    ing = median_of(files, ["per_ingest_us"])
    ret = median_of(files, ["avg_retrieval_us"])
    if ing is None or ret is None:
        return False, "per_ingest_us / avg_retrieval_us missing in JSONs"
    err_ing = abs(ing - 4840) / 4840 * 100
    err_ret = abs(ret - 638) / 638 * 100
    if err_ing > tol_pct or err_ret > tol_pct:
        return False, f"DRIFT: median ingest={ing:.0f} (paper 4840, {err_ing:.1f}%)  retrieval={ret:.0f} (paper 638, {err_ret:.1f}%)"
    return True, f"OK ingest={ing:.0f} retrieval={ret:.0f} (paper 4840 / 638, tol {tol_pct}%)"


def check_t3_sqlite_precompute_iphone(paper: str, tol_pct: float = 10.0) -> tuple[bool, str]:
    """Table 3 — SQLite-Precompute iPhone ingest 317.10 / retrieval 27.6 µs."""
    if not assert_in_paper(paper, r"SQLite-Precompute\s*\|\s*207\.77 / 75\.0\s*\|\s*317\.10 / 27\.6\s*\|"):
        return False, "T3 SQLite-Precompute iPhone row not found"
    files = load_jsons("iPhone_12_Pro/sqlite-precompute/storageonly_sqlite-precompute_*.json")
    if len(files) < 3:
        return False, f"Need 3 sqlite-precompute runs; found {len(files)}"
    ing = median_of(files, ["per_ingest_us"])
    ret = median_of(files, ["avg_retrieval_us"])
    if ing is None or ret is None:
        return False, "per_ingest_us / avg_retrieval_us missing"
    err = abs(ing - 317.10) / 317.10 * 100
    if err > tol_pct:
        return False, f"DRIFT ingest={ing:.2f} vs paper 317.10 ({err:.1f}%)"
    err_ret = abs(ret - 27.6) / 27.6 * 100
    if err_ret > tol_pct:
        return False, f"DRIFT retrieval={ret:.2f} vs paper 27.6 ({err_ret:.1f}%)"
    return True, f"OK ingest={ing:.2f} retrieval={ret:.2f}"


def check_t11_dazzle_sq8_n20k(paper: str, tol_pct: float = 5.0) -> tuple[bool, str]:
    """Table 11 — Dazzle SQ8 at N=20 000 reaches 208 µs p50 search at recall 0.959 with ~9.77 MB analytical RAM."""
    if not assert_in_paper(paper, r"\*\*Dazzle SQ8\*\*\s*\|.*?int8\s*\|\s*0\.959\s*\|\s*\*\*208 µs\*\*"):
        return False, "T11 Dazzle SQ8 row not found verbatim"
    if not assert_in_paper(paper, r"9\.77 MB \$\\dagger\$"):
        return False, "T11 Dazzle SQ8 RAM/DB cell missing 9.77 MB analytical figure"
    files = load_jsons("Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json")
    if not files:
        return False, "Final paper-grade Moto vector JSON missing"
    cfg_n20k = next((c for c in files[0]["configs"] if c.get("n_docs") == 20000), None)
    if not cfg_n20k:
        return False, "N=20000 config not present"
    sq8 = cfg_n20k.get("dazzle_sq8") or {}
    op = best_ef(sq8, floor=0.95)
    if not op:
        return False, "Dazzle SQ8 by_ef has no entry meeting recall floor 0.95"
    err = abs(op["search_lat_us"]["p50"] - 208) / 208 * 100
    if err > tol_pct:
        return False, f"DRIFT p50={op['search_lat_us']['p50']} vs paper 208 ({err:.1f}%)"
    return True, f"OK p50={op['search_lat_us']['p50']} recall={op['recall_at_k']:.3f} (paper 208 µs / 0.959)"


def check_t11_sqlite_plain_size(paper: str, tol_pct: float = 5.0) -> tuple[bool, str]:
    """Table 11 — sqlite_plain DB size 79.45 MB at N=20 000."""
    if not assert_in_paper(paper, r"sqlite\\_plain\s*\|.*?\|\s*1\.000\s*\|\s*707 302 µs.*?79\.45 MB"):
        return False, "T11 sqlite_plain row not found"
    files = load_jsons("Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json")
    if not files:
        return False, "Final Moto vector JSON missing"
    cfg = next((c for c in files[0]["configs"] if c.get("n_docs") == 20000), None)
    db_bytes = (cfg.get("sqlite") or {}).get("db_file_bytes")
    if db_bytes is None or db_bytes < 0:
        return False, "sqlite db_file_bytes missing or -1"
    mb = db_bytes / 1024 / 1024
    err = abs(mb - 79.45) / 79.45 * 100
    if err > tol_pct:
        return False, f"DRIFT db_size={mb:.2f}MB vs paper 79.45MB ({err:.1f}%)"
    return True, f"OK db_size={mb:.2f}MB (paper 79.45MB)"


def check_t4_dazzle_vector_moto(paper: str, tol_pct: float = 10.0) -> tuple[bool, str]:
    """Table 4 — Dazzle-Vector Moto 74 / 65 µs at N=200, recall 1.0."""
    if not assert_in_paper(paper, r"\*\*Dazzle-Vector \(HNSW\)\*\*\s*\|\s*\*\*74 / 65\*\*"):
        return False, "T4 Dazzle-Vector Moto cell not found"
    files = load_jsons("Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json")
    if not files:
        return False, "Final Moto vector JSON missing"
    cfg_n200 = next((c for c in files[0]["configs"] if c.get("n_docs") == 200), None)
    hnsw = cfg_n200.get("dazzle_hnsw") or {}
    op = best_ef(hnsw, floor=0.95)
    ing = hnsw.get("ingest_avg_us")
    if not op or ing is None:
        return False, "dazzle_hnsw N=200 missing by_ef or ingest_avg_us"
    err_ing = abs(ing - 74) / 74 * 100
    err_p50 = abs(op["search_lat_us"]["p50"] - 65) / 65 * 100
    if err_ing > tol_pct or err_p50 > tol_pct:
        return False, f"DRIFT ingest={ing:.1f} (paper 74) p50={op['search_lat_us']['p50']} (paper 65)"
    return True, f"OK ingest={ing:.1f} p50={op['search_lat_us']['p50']} recall={op['recall_at_k']:.3f}"


def check_inference_ratio(paper: str) -> tuple[bool, str]:
    """Abstract + conclusion: 50 µs retrieval / ~2.84 s inference = 0.00176 %."""
    actual = 50e-6 / 2.84
    actual_pct = actual * 100
    asserted_pct = 0.00176
    if not assert_in_paper(paper, r"0\.00176\s*\\?%"):
        return False, "Abstract / conclusion no longer asserts 0.00176 %"
    err = abs(actual_pct - asserted_pct) / asserted_pct * 100
    if err > 5:
        return False, f"DRIFT: 50µs / 2.84s = {actual_pct:.5f}% vs asserted 0.00176% ({err:.2f}%)"
    return True, f"OK 50µs / 2.84s = {actual_pct:.5f}% (paper 0.00176%)"


def check_factorial_arithmetic(paper: str) -> tuple[bool, str]:
    """§5.4 ablation — snap-ser exceeds hash-par by ~1.8% (precompute)
    and ~2.1% (incremental). Verifies the arithmetic on the raw Table 7
    numbers actually matches the prose claim."""
    if not assert_in_paper(paper, r"snap-ser is 1\.8\s*%\s*above hash-par for"):
        return False, "§5.4 closing prose 'snap-ser is 1.8% above hash-par' not found"
    inc_ratio = 28897 / 28304
    pre_ratio = 38830 / 38156
    inc_pct = (inc_ratio - 1) * 100
    pre_pct = (pre_ratio - 1) * 100
    if not (1.5 <= pre_pct <= 2.0):
        return False, f"DRIFT precompute snap-ser/hash-par = {pre_pct:.2f}%, paper claims 1.8%"
    if not (1.9 <= inc_pct <= 2.4):
        return False, f"DRIFT incremental snap-ser/hash-par = {inc_pct:.2f}%, paper claims 2.1%"
    return True, f"OK precompute={pre_pct:.2f}% incremental={inc_pct:.2f}%"


def check_t15_rag_metrics(paper: str) -> tuple[bool, str]:
    """Table 15 — full 2×2 matrix anchors:
       Qwen 0.5B no-RAG       EM_short 0.015 / EM_contains 0.105
       Qwen 0.5B + Dazzle RAG EM_short 0.120 / EM_contains 0.630
       Qwen 1.5B no-RAG       EM_short 0.045 / EM_contains 0.110
       Qwen 1.5B + Dazzle RAG EM_short 0.310 / EM_contains 0.735
       Source JSON: research/benchmarks/results/Moto_G35_5G/rag_2x2/
                    rag_e2e_moto_g35_5G_1777395311213.json
                    (sha256 00d21f6c8752ffaa1015624b69a5e5d0fd403670d72561e3838bdac0ab461e76)
    """
    # Wave 2 added bootstrap 95 % CIs in `[lo, hi]` brackets next to each
    # anchor; the regex now accepts the optional bracketed CI without
    # checking its specific bounds (those are validated separately by the
    # bootstrap script's own self-check). The point estimates are still
    # checked exactly.
    rows = [
        (r"Qwen 0\.5B \(no RAG\)\s*\|\s*380 MB\s*\|\s*0\.015\b",
         "T15 Qwen 0.5B no-RAG EM_short 0.015"),
        (r"Qwen 0\.5B \+ Dazzle RAG\s*\|\s*380 MB\s*\|\s*\*\*0\.120\*\*",
         "T15 Qwen 0.5B + RAG EM_short 0.120"),
        (r"Qwen 1\.5B \(no RAG\)\s*\|\s*940 MB\s*\|\s*0\.045\b",
         "T15 Qwen 1.5B no-RAG EM_short 0.045"),
        (r"Qwen 1\.5B \+ Dazzle RAG\s*\|\s*940 MB\s*\|\s*\*\*0\.310\*\*",
         "T15 Qwen 1.5B + RAG EM_short 0.310"),
        # EM_contains anchors (the headline metric) — match without the
        # CI bracket since pandoc's table cell rendering may rewrap.
        (r"\b0\.105\b.*\b0\.630\b",
         "T15 EM_contains 0.5B values present"),
        (r"\b0\.110\b.*\b0\.735\b",
         "T15 EM_contains 1.5B values present"),
    ]
    for pat, label in rows:
        if not assert_in_paper(paper, pat):
            return False, f"{label} not found (or anchors drifted)"
    # cross-references in abstract / contributions / conclusion
    cross = [
        (r"0\.630 vs 0\.105 without RAG \(6\.0", "abstract/contrib 0.5B 6.0× claim"),
        (r"0\.735 vs 0\.110 without RAG \(6\.7", "abstract/contrib 1.5B 6.7× claim"),
    ]
    for pat, label in cross:
        if not assert_in_paper(paper, pat):
            return False, f"{label} drifted vs T15"
    return True, "OK 4/4 rows + 2/2 cross-refs match T15 anchors"


def _read_companion() -> str:
    p = REPO / "research" / "paper" / "companion_engineering_report.md"
    return p.read_text(encoding="utf-8") if p.exists() else ""


def _read_sdk_adapters() -> str:
    p = REPO / "docs" / "sdk" / "llm_adapters.md"
    return p.read_text(encoding="utf-8") if p.exists() else ""


def check_invariants_appendix(paper: str) -> tuple[bool, str]:
    """The three EventChannel invariants live in (a) the companion
    report §3.1 and (b) the SDK adapter reference at
    docs/sdk/llm_adapters.md (Wave-1 task 1.6: paper Appendix A is
    now a 2-paragraph pointer). The paper itself no longer carries
    the invariant detail; checking that the two reference targets
    do."""
    companion = _read_companion()
    sdk = _read_sdk_adapters()
    needed_companion = [
        r"Invariant 1 — Tasks per subscription",
        r"Invariant 2 — Never call `events\(FlutterEndOfEventStream\)`",
        r"Invariant 3 — `streamId` cookie filters residual frames",
    ]
    for n in needed_companion:
        if not assert_in_paper(companion, n):
            return False, f"companion missing invariant detail: {n}"
    if "tasksBySubId" not in sdk or "streamId" not in sdk:
        return False, "docs/sdk/llm_adapters.md missing key invariant terms (Wave 1.6 move)"
    if "docs/sdk/llm_adapters.md" not in paper:
        return False, "paper Appendix A does not point at docs/sdk/llm_adapters.md"
    return True, "OK 3/3 in companion + key terms in SDK adapter reference + paper points at SDK doc"


def check_anthropic_matrix(paper: str) -> tuple[bool, str]:
    """Live-verification matrix lives in companion §3.2 and the
    `4 / 4` result is repeated in docs/sdk/llm_adapters.md after the
    Wave-1 task 1.6 trim. The paper Appendix A no longer carries
    the matrix detail."""
    companion = _read_companion()
    sdk = _read_sdk_adapters()
    needed_rows = [
        r"React Native, Android \(Moto G35 5G\)\s*\|\s*`chat-kb-rn`",
        r"iOS native \(simulator, iPhone 17 Pro\)\s*\|\s*`DazzleChatMemory`",
        r"Flutter, Android \(Moto G35 5G\)",
        r"Flutter, iOS \(simulator\)",
    ]
    for n in needed_rows:
        if not assert_in_paper(companion, n):
            return False, f"companion missing matrix row: {n}"
    if "4 / 4" not in sdk and "4/4" not in sdk:
        return False, "docs/sdk/llm_adapters.md missing 4/4 result (Wave 1.6 move target)"
    return True, "OK 4/4 rows in companion + 4/4 result in SDK adapter reference"


def check_companion_report(paper: str) -> tuple[bool, str]:
    """QW3-08 + Wave 1.6 — content moved out of the paper must
    (a) exist in the companion or SDK reference file and (b) leave
    a pointer in the paper. Wave 1.6 trimmed Appendix A so the
    `## A.2 …` stub is no longer expected; instead the paper must
    point at docs/sdk/llm_adapters.md."""
    companion = REPO / "research" / "paper" / "companion_engineering_report.md"
    if not companion.exists():
        return False, "companion_engineering_report.md missing"
    text = companion.read_text(encoding="utf-8")
    needed_in_companion = [
        "Performance evolution of the Dazzle stack",
        "SQLite-family vector N-sweep",
        "Three Flutter `EventChannel` bridge invariants",
        "Live verification matrix",
    ]
    missing = [n for n in needed_in_companion if n not in text]
    if missing:
        return False, f"companion missing sections: {missing}"
    needed_paper_stubs = [
        "## 5.7 Performance Evolution (summary)",
        "### 5.8.4 SQLite Extension Variant Sweep — summary",
        "docs/sdk/llm_adapters.md",
        "research/paper/companion_engineering_report.md",
    ]
    missing_p = [s for s in needed_paper_stubs if s not in paper]
    if missing_p:
        return False, f"paper stubs missing: {missing_p}"
    return True, "OK companion + SDK reference present + paper pointers in place"


def check_t9_platform_split(paper: str) -> tuple[bool, str]:
    """QW3-06 — Table 9 must report Android + iOS SLOC separately."""
    needles = [
        "Android (Kotlin) SLOC",
        "iOS (Swift) SLOC",
        "Sum (both)",
        "**Dazzle**",
        "**175**",
        "**186**",
        "**361**",
    ]
    missing = [n for n in needles if n not in paper]
    if missing:
        return False, f"T9 platform-split table missing: {missing}"
    return True, "OK Android/iOS/sum columns present"


def check_dazzle_ram_analytical(paper: str) -> tuple[bool, str]:
    """QW3-02 — Dazzle DB-size cells in T11 must be analytical
    (vectors + HNSW graph), not the bogus 50.4 KB used_memory_dataset."""
    forbidden = "50.4 KB"
    if forbidden in paper:
        return False, f"T11 still has stale '{forbidden}' cells"
    needed = ["9.77 MB", "39.06 MB", "17.09 MB", "31.74 MB", "graph alone = 2.44 MB"]
    missing = [n for n in needed if n not in paper]
    if missing:
        return False, f"T11 analytical RAM footnote missing: {missing}"
    return True, "OK T11 analytical sizes (9.77 / 17.09 / 31.74 / 39.06 MB) present"


def check_t11_t12_reconciliation(paper: str) -> tuple[bool, str]:
    """QW3-01 — the T11 SQLiteAI rows must carry an asterisk that
    refers to the dedicated 3-round companion sweep, and the audit
    doc must exist."""
    audit = REPO / "research" / "PAPER_T11_T12_RECONCILIATION.md"
    if not audit.exists():
        return False, "PAPER_T11_T12_RECONCILIATION.md missing"
    # Wave 1.2 moved the explicit "between **6.8× faster** /
    # **14.8× faster**" emphasis out of §5.8.2 into the §5.8.4
    # Algorithm-class disclosure. Anchor against the surviving
    # ratio mention "6.8×–14.8×" + the disclosure header.
    needles = [
        "SQLiteAI default $*$",
        "SQLiteAI optimized $*$",
        "SQLiteAI precompute $*$",
        "single-shot from the cross-engine",
        "9 812 ± 363 µs",
        "3 072 ± 4 µs",
        "6.8×–14.8×",
        "Algorithm-class disclosure",
    ]
    missing = [n for n in needles if n not in paper]
    if missing:
        return False, f"T11 reconciliation anchors missing: {missing}"
    return True, "OK T11 SQLiteAI rows starred + companion-T2 numbers cited + audit doc present"


def check_post_fix_json_cite(paper: str) -> tuple[bool, str]:
    """QW3-07 — §5.2 must cite the post-fix Moto vector JSON with
    its SHA-256 and the fix-commit hash."""
    json_path = "research/benchmarks/results/Moto_G35_5G/vector/vecbench_moto_g35_5G_1777369156656.json"
    sha = "5a64d3692da166d96306d456697e43bb89c27c07b515e253346c5b33bc5c9b5b"
    fix_commit = "1e3d5f5"
    if json_path not in paper:
        return False, "post-fix JSON path not cited in paper §5.2"
    if sha not in paper:
        return False, f"post-fix JSON SHA-256 not in paper (expected {sha[:16]}...)"
    if fix_commit not in paper:
        return False, f"fix commit hash {fix_commit} not cited in §5.2"
    return True, f"OK §5.2 cites JSON {json_path[-32:]} + SHA + commit {fix_commit}"


def check_gemma_artifact_pin(paper: str) -> tuple[bool, str]:
    """QW3-05 — Gemma 4 cite must carry both URL and SHA-256, and
    the SHA must agree with docs/sdk/edge_models.json."""
    bib = (REPO / "research" / "paper" / "arxiv-build" / "refs.bib").read_text(encoding="utf-8")
    expected_sha = "ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42"
    if expected_sha not in bib:
        return False, "@gemma4 bib entry missing SHA-256"
    if "huggingface.co/litert-community/gemma-4-E2B-it" not in bib:
        return False, "@gemma4 bib entry missing HF URL"
    manifest_path = REPO / "docs" / "sdk" / "edge_models.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest_sha = (manifest.get("models", {})
                        .get("gemma-4-E2B-it", {})
                        .get("sha256", ""))
        if manifest_sha != expected_sha:
            return False, f"edge_models.json SHA mismatch: bib has {expected_sha[:16]}..., manifest has {manifest_sha[:32]}"
    return True, "OK @gemma4 has SHA + URL; manifest agrees"


def check_two_preset_table(paper: str) -> tuple[bool, str]:
    """§5.8.1 must explicitly distinguish the two harness presets to
    avoid the recall-regression confusion."""
    # Use simple substring containment rather than a brittle regex —
    # the markdown carries `$\times$` literally, but pandoc may
    # rewrite that, and the test should be insensitive to either form.
    needles = [
        "`DEFAULT_CONFIGS`",
        "9 (3 dim $\\times$ 3 N)",
        "`vector-bench-paper384-scale`",
        "`paper384_scale`",
        "4 (1 dim $\\times$ 4 N)",
    ]
    missing = [n for n in needles if n not in paper]
    if missing:
        return False, f"§5.8.1 two-preset table missing: {missing}"
    return True, f"OK two-preset table present ({len(needles)} anchors)"


def check_squad_scorer_audit(paper: str) -> tuple[bool, str]:
    """Run the SQuAD-protocol scorer audit suite
    (research/scripts/test_rag_scoring.py). All 31 unit tests must
    pass; failure means either the scorer drifted vs. the SQuAD
    protocol or the cited Table 15 numbers no longer match the JSON
    re-score (which would invalidate every Sec 5.9 cell).
    """
    import subprocess
    test_file = REPO / "research" / "scripts" / "test_rag_scoring.py"
    if not test_file.exists():
        return False, f"missing: {test_file}"
    res = subprocess.run(
        ["python3", str(test_file)],
        capture_output=True, text=True, cwd=str(REPO),
    )
    # unittest writes its summary to stderr ("Ran X tests in Ys / OK").
    out = res.stdout + res.stderr
    if res.returncode != 0:
        # Surface only the failing test names + counts (the full
        # traceback is in the test_file output if a maintainer wants
        # to dig deeper).
        last = out.strip().splitlines()[-3:]
        return False, f"scorer audit FAILED: {' | '.join(last)}"
    # Verify the suite ran the expected number of tests so that a
    # silent skip (e.g. fixture missing) cannot pass the check.
    import re
    m = re.search(r"Ran (\d+) tests", out)
    n = int(m.group(1)) if m else 0
    if n < 25:
        return False, f"scorer audit ran only {n} tests (expected ≥25 — fixture or cited JSON missing?)"
    return True, f"OK {n}/{n} SQuAD-protocol tests pass (fixture + cited-run regression)"


def check_kotlin_python_scorer_parity(paper: str) -> tuple[bool, str]:
    """Structural-parity check between the Python scorer
    (research/scripts/recompute_rag_metrics.py) and the Kotlin scorer
    (experiment/backends/android/core/RagE2EBench.kt). Both must
    define the same STOP set, the same regex / character classes used
    for normalisation, and the same span-extraction terminator list.
    Any drift here means an on-device run could disagree with offline
    re-scoring — which is the exact failure mode that produced the
    Sec 5.9.2 erratum in v1 of the paper.
    """
    py_path = REPO / "research" / "scripts" / "recompute_rag_metrics.py"
    kt_path = REPO / "experiment" / "backends" / "android" / "core" / "RagE2EBench.kt"
    if not py_path.exists() or not kt_path.exists():
        return False, "scorer source files missing"
    py = py_path.read_text(encoding="utf-8")
    kt = kt_path.read_text(encoding="utf-8")

    # Anchor 1: STOP set — must be the SQuAD English articles
    if 'STOP = {"a", "an", "the"}' not in py:
        return False, "Python STOP set drifted — must be {a, an, the}"
    if 'STOP = setOf("a", "an", "the")' not in kt:
        return False, "Kotlin STOP set drifted — must be setOf(a, an, the)"

    # Anchor 2: span-extraction terminators — newline, `Question:`, `Answer:`
    py_terminators = '("\\n", "Question:", "Answer:")'
    kt_terminators = 'listOf("\\n", "Question:", "Answer:")'
    if py_terminators not in py:
        return False, f"Python span terminators drifted — expected {py_terminators}"
    if kt_terminators not in kt:
        return False, f"Kotlin span terminators drifted — expected {kt_terminators}"

    # Anchor 3: function-signature parallelism — Python and Kotlin must
    # both expose em_strict / em_contains / f1_short with the same
    # extracted-span-vs-full-pred contract.
    py_funcs = ["def em_strict(", "def em_contains(", "def f1_short(", "def extract_answer_span("]
    kt_funcs = ["fun emStrict(", "fun emContains(", "fun f1Short(", "fun extractAnswerSpan("]
    py_missing = [f for f in py_funcs if f not in py]
    kt_missing = [f for f in kt_funcs if f not in kt]
    if py_missing or kt_missing:
        return False, f"function parallelism drift py={py_missing} kt={kt_missing}"

    return True, "OK STOP set + span terminators + 4-function surface match across Python/Kotlin"


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

PAPER_CHECKS: dict[str, Callable[[str], tuple[bool, str]]] = {
    "T3-ObjectBox-iPhone":         check_t3_objectbox_iphone,
    "T3-SQLite-Precompute-iPhone": check_t3_sqlite_precompute_iphone,
    "T4-Dazzle-Vector-Moto":       check_t4_dazzle_vector_moto,
    "T9-platform-split":           check_t9_platform_split,
    "T11-Dazzle-SQ8-N20k":         check_t11_dazzle_sq8_n20k,
    "T11-Dazzle-RAM-analytical":   check_dazzle_ram_analytical,
    "T11-sqlite-plain-size":       check_t11_sqlite_plain_size,
    "T15-RAG-anchors":             check_t15_rag_metrics,
    "Inference-ratio-0.00176%":    check_inference_ratio,
    "Factorial-arithmetic-1.8%":   check_factorial_arithmetic,
    "AppendixA-EventChannel-3":    check_invariants_appendix,
    "AppendixA-Anthropic-matrix":  check_anthropic_matrix,
    "5.8.1-two-presets":           check_two_preset_table,
    "Companion-report":            check_companion_report,
    "T11-T12-reconciliation":      check_t11_t12_reconciliation,
    "Post-fix-JSON-cite":          check_post_fix_json_cite,
    "Gemma-artifact-pin":          check_gemma_artifact_pin,
    "SQuAD-scorer-audit":          check_squad_scorer_audit,
    "Kotlin-Python-scorer-parity": check_kotlin_python_scorer_parity,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma-separated subset of check ids")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    paper = load_paper()
    selected = (args.only.split(",") if args.only
                else list(PAPER_CHECKS.keys()))
    fails: list[str] = []
    print(f"check_paper_consistency.py — {len(selected)} checks")
    print(f"paper:   {PAPER.relative_to(REPO)}")
    print(f"results: {RESULTS.relative_to(REPO)}\n")

    for name in selected:
        if name not in PAPER_CHECKS:
            print(f"  ?  {name:<32} unknown check id")
            fails.append(name)
            continue
        ok, msg = PAPER_CHECKS[name](paper)
        glyph = "✓" if ok else "✘"
        print(f"  {glyph}  {name:<32} {msg}")
        if not ok:
            fails.append(name)

    print(f"\n{len(fails)} drift(s) / missing anchor(s)" if fails else "\nAll consistent.")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
