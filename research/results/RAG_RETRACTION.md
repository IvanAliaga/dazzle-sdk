# RAG benchmark JSON retraction

## What was removed

The following three JSON files were committed in error and removed from
the working tree in the retraction commit:

- `rag_e2e_moto_g35_5G.json` (50 queries, no EM scoring yet, 2026-04-23T06:57:38Z)
- `rag_e2e_moto_g35_5G_em.json` (50 queries, buggy `em_short` / `f1_short`, 2026-04-23T07:32:54Z)
- `rag_e2e_moto_g35_5G_em_q200.json` (200 queries, buggy `em_short` / `f1_short`, 2026-04-23T08:26:16Z)

## Why

The two `*_em*.json` files contain the buggy `em_short` and `f1_short`
metrics documented in the §5.9.2 erratum of the Dazzle paper:

- `em_short` was implemented as a substring match on the full 64-token
  generation rather than the SQuAD-protocol exact match on the
  extracted span. A verbose-but-correct reply scored 1.
- `f1_short` was computed token-by-token over the same full generation,
  so the same verbose reply was heavily penalised by the surrounding
  prose.

The two formulas together produced the pair `EM_short = 0.665, F1_short = 0.077`
for `small_rag` at n = 200, which violates the SQuAD-style invariant
`EM ≤ F1` per sample (and therefore per average) and is mathematically
impossible.

These JSONs predate the scoring fix described in §5.9.1 of the paper
and **must not be used for any analysis**.

The first file (`rag_e2e_moto_g35_5G.json`, no EM yet) is also removed
because it shares the buggy harness genealogy and could be confused with
the post-fix run by name.

## Replacement

The 2×2 RAG matrix reported in Table 15 of the paper comes from a single
post-fix bench run, archived at:

- `research/benchmarks/results/Moto_G35_5G/rag_2x2/rag_e2e_moto_g35_5G_1777395311213.json`
- SHA-256: `00d21f6c8752ffaa1015624b69a5e5d0fd403670d72561e3838bdac0ab461e76`

That JSON contains the four variants (`small_no_rag`, `small_rag`,
`large_no_rag`, `large_rag`) measured back-to-back in a single harness
invocation; the top-level timestamp `2026-04-28T12:48:37.556130Z` is the
launch time, and the four variants share that one launch.

## How to verify the retraction

After the retraction commit:

    git log --diff-filter=D -- research/results/rag_e2e_moto_g35_5G*.json

shows the three files being removed. The git history retains the buggy
content for traceability — see commit `f999003` (the original buggy
bench run) and the retraction commit immediately following this notice.

## How to discard already-cloned copies

If you cloned the repository before the retraction commit, after pulling
`main` the three files will be deleted from your working tree. To force
the cleanup:

    git pull
    # or, manually:
    rm research/results/rag_e2e_moto_g35_5G.json \
       research/results/rag_e2e_moto_g35_5G_em.json \
       research/results/rag_e2e_moto_g35_5G_em_q200.json

## Files NOT retracted

- `research/results/rag_e2e_moto_g35_5G_1777191828315.json` — a
  post-fix single-variant run (Apr 26) that uses the corrected
  scoring (`EM_short = 0.090, F1_short = 0.186`, `EM ≤ F1` holds).
  Kept for partial-history reference; superseded for paper purposes
  by the 2×2 JSON cited above.
- `research/results/rag_moto_g35_5G.json` — earlier non-EM bench;
  not part of the §5.9 evaluation pipeline.
