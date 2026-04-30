#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
"""Compare the v1 buggy RAG run with the post-fix 2x2 run on the 10
per-variant examples that v1 persisted (the v1 harness wrote only
the first 10 of the 200-query run to `examples`; the post-fix
harness writes all 200).

Output: research/results/v1_vs_postfix_diff.md — a verifiable
side-by-side of the 20 (qid, variant) pairs both runs share, with
the model-file byte-size delta between the two runs called out
explicitly.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
V1_GIT_REF = "80f465e:research/results/rag_e2e_moto_g35_5G_em_q200.json"
POST_PATH = (
    REPO
    / "research"
    / "benchmarks"
    / "results"
    / "Moto_G35_5G"
    / "rag_2x2"
    / "rag_e2e_moto_g35_5G_1777395311213.json"
)
OUT = REPO / "research" / "results" / "v1_vs_postfix_diff.md"


def load_v1() -> dict:
    """Recover the retracted v1 JSON from git history (commit 80f465e
    introduced it; commit 2802527 retracted it from HEAD)."""
    raw = subprocess.run(
        ["git", "show", V1_GIT_REF],
        check=True, cwd=str(REPO),
        capture_output=True, text=True,
    ).stdout
    return json.loads(raw)


def main() -> int:
    v1 = load_v1()
    post = json.loads(POST_PATH.read_text(encoding="utf-8"))

    common_variants = sorted(set(v1["variants"]) & set(post["variants"]))
    if not common_variants:
        raise SystemExit("no common variants between v1 and post-fix")

    lines: list[str] = []
    lines.append("# v1 vs post-fix RAG generation diff\n")
    lines.append(
        "Comparison between the v1 RAG run (commit `80f465e`, retracted "
        "from HEAD in commit `2802527`) and the post-fix 2×2 run cited "
        "in Table 15. Both runs are on Moto G35 5G with the same NQ slice "
        "(2 000 passages, 200 queries, k=5, ef_runtime=64, max_new_tokens=64, "
        "greedy decoding). v1 persisted only the first 10 examples per "
        "variant, post-fix persisted all 200; this report covers the "
        "10 (qid × variant) pairs both runs share.\n"
    )

    # ── model-file sanity ─────────────────────────────────────────
    lines.append("## Run metadata\n")
    lines.append(f"- v1 timestamp:        `{v1['timestamp']}`")
    lines.append(f"- post-fix timestamp:  `{post['timestamp']}`")
    lines.append("")

    lines.append("## Model files compared\n")
    lines.append("| Slot       | v1 file size                 | post-fix file size           | Δ bytes      |")
    lines.append("|------------|------------------------------|------------------------------|--------------|")
    same_models = True
    for slot in ("embedder", "small_llm", "large_llm"):
        v1m = v1["models"].get(slot, {})
        pm = post["models"].get(slot, {})
        v1b = v1m.get("size_bytes", 0)
        pb = pm.get("size_bytes", 0)
        d = pb - v1b
        if d != 0:
            same_models = False
        lines.append(
            f"| `{slot:<10}` | `{v1m.get('file','—')}` ({v1b:>12} B) "
            f"| `{pm.get('file','—')}` ({pb:>12} B) "
            f"| {d:+d} |"
        )
    lines.append("")

    if same_models:
        lines.append(
            "Model files are byte-identical between the two runs. The v1 vs "
            "post-fix difference is therefore confined to the scorer.\n"
        )
    else:
        lines.append(
            "**Model files differ in byte size between the two runs.** This "
            "means the v1 vs post-fix comparison is *not* a pure scorer "
            "diff — the on-device generations are produced by two related but "
            "not byte-identical model artefacts (likely different `q4_k_m` "
            "repacks of the same upstream Qwen 2.5 weights). Per-row "
            "generation diffs in this report should therefore be read as a "
            "*combined effect* (model-artefact change + scorer fix), and the "
            "erratum text in §5.9.2 is updated accordingly.\n"
        )

    # ── per-variant per-qid diff ──────────────────────────────────
    lines.append("## Per-variant generation diff (10 anchor cases)\n")

    summary = {}
    for vname in common_variants:
        v1_ex = {e["qid"]: e for e in v1["variants"][vname]["examples"]}
        post_ex = {e["qid"]: e for e in post["variants"][vname]["examples"]}
        common = sorted(set(v1_ex) & set(post_ex))
        same_text = 0
        diff_text = 0
        same_em = 0
        em_change = 0
        for qid in common:
            a1 = v1_ex[qid].get("answer", "")
            a2 = post_ex[qid].get("answer", "")
            if a1 == a2:
                same_text += 1
            else:
                diff_text += 1
            em1 = v1_ex[qid].get("em_short")
            em2 = post_ex[qid].get("em_short")
            if em1 == em2:
                same_em += 1
            else:
                em_change += 1
        summary[vname] = (len(common), same_text, diff_text, same_em, em_change)

        lines.append(f"### Variant `{vname}` (n = {len(common)} common qids)\n")
        lines.append(
            f"- Generations identical: **{same_text}** of {len(common)}\n"
            f"- Generations differ:    **{diff_text}** of {len(common)}\n"
            f"- `em_short` agrees:     {same_em} of {len(common)}\n"
            f"- `em_short` changed:    {em_change} of {len(common)}\n"
        )

        # show the actual diffs side by side
        lines.append("| qid | v1 answer (first 90 chars) | post-fix answer (first 90 chars) | identical? |")
        lines.append("|-----|----------------------------|----------------------------------|:----------:|")
        for qid in common:
            a1 = (v1_ex[qid].get("answer") or "").strip().replace("|", "\\|").replace("\n", " ")
            a2 = (post_ex[qid].get("answer") or "").strip().replace("|", "\\|").replace("\n", " ")
            mark = "✓" if a1 == a2 else "✗"
            lines.append(f"| `{qid}` | `{a1[:90]}` | `{a2[:90]}` | {mark} |")
        lines.append("")

    # ── summary ───────────────────────────────────────────────────
    lines.append("## Summary\n")
    lines.append("| Variant       | n  | identical generations | identical em_short |")
    lines.append("|---------------|----|----------------------:|-------------------:|")
    for vname, (n, st, dt, se, ec) in summary.items():
        lines.append(f"| `{vname}` | {n} | {st} ({100*st/n:.0f} %) | {se} ({100*se/n:.0f} %) |")
    lines.append("")

    if same_models and all(s == n for n, s, _, _, _ in summary.values()):
        verdict = (
            "**Verdict.** All anchor cases have byte-identical generations "
            "between v1 and post-fix on byte-identical model files, so the "
            "v1 vs post-fix delta in `EM_short` and `F1_short` is **purely** "
            "a scorer-formula change. The §5.9.2 erratum's claim of "
            "behaviour-preservation across the two runs is empirically "
            "supported on these 10/200 anchor cases."
        )
    elif not same_models:
        verdict = (
            "**Verdict.** Model files changed between v1 and post-fix, so "
            "the v1 vs post-fix delta is a **combined effect** of "
            "(a) model-artefact change and (b) scorer-formula fix. The "
            "§5.9.2 erratum should not claim pure scorer-isolation; the "
            "honest framing is *\"two related runs of the same workload "
            "with different model artefacts and a fixed scorer; both the "
            "scorer and the generations changed.\"* The post-fix run is "
            "the canonical one cited in Table 15."
        )
    else:
        verdict = (
            "**Verdict.** Model files are byte-identical but some "
            "generations differ at the anchor cases. Update the erratum "
            "to note partial behaviour drift even at fixed model bytes "
            "(possible causes: different KV-cache layout, different "
            "decoding prefix from a harness change between runs)."
        )
    lines.append(verdict)
    lines.append("")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
