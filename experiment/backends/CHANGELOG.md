# Backend wrappers — CHANGELOG

This file is the public ledger of optimisations accepted into the
benchmark wrappers under `experiment/backends/{android,ios}/`. The
Dazzle paper (§6.3, Conflict-of-Interest commitment) cites this
file as the public-commitment artefact for falsifiable comparison
numbers.

External pull requests that **reduce LOC count** of any non-Dazzle
wrapper, or that **improve a non-Dazzle backend's measured
numbers** in Tables 3 / 5 / 11 of the paper, are reviewed on
technical merit and merged when sound. Each merged optimisation is
recorded here with: contributor, scope, measured effect, and the
paper revision in which the new numbers first appear.

The CHANGELOG is structured chronologically with the most recent
entry first. The "Paper revision" column refers to the
`research/paper/paper_v2_en.md` revision tag (currently the v2 line)
or to the next planned revision.

---

## Entry template

```
## YYYY-MM-DD — short title

- **Contributor**: GitHub handle / name
- **Backend**: dazzle | sqlite | sqlite-precompute | sqlite-optimized
              | lmdb | rocksdb | objectbox | inmemory
- **Wrapper file(s)**:
    experiment/backends/<plat>/<backend>/<File>.kt
- **Scope**: LOC reduction / latency improvement / footprint reduction
            / correctness fix
- **Before → After**:
    LOC: <N1> → <N2>
    or
    Retrieval avg µs at N=<N>: <X1> → <X2> (delta -<Y>%)
- **PR**: #<number>
- **Paper revision**: v2.X (incorporated) | next revision (planned)
- **Bench JSON**: research/benchmarks/results/.../<file>.json
                 (sha256 <prefix>)
- **Notes**: <one paragraph on why the change is sound, what
             behaviour it preserves, and any caveats>
```

---

## 2026-04-28 — CHANGELOG initialised

- **Contributor**: Ivan Aliaga (paper author — initial entry)
- **Backend**: n/a (administrative)
- **Scope**: governance — establishes the public ledger
- **Paper revision**: v2 (this revision)
- **Notes**: This file establishes the public-commitment
  protocol announced in §6.3 of the paper. No optimisations are
  recorded yet; the existing wrappers are the v2 baseline against
  which future contributed improvements will be measured. The
  baseline LOC numbers cited in Table 9 — 175 (Android) / 186
  (iOS) for Dazzle versus 200–290 across the alternatives — are
  the values to beat.
