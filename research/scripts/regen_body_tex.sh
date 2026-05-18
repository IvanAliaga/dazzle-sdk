#!/usr/bin/env bash
# Regenerate `arxiv-build/body.tex` and `arxiv-build/body_es.tex` from
# `paper_v2_en.md` / `paper_v2_es.md`. Strips manual section-number
# prefixes (e.g. `## 5.9.1 Setup` → `## Setup`) so pandoc emits LaTeX
# that `arxiv.sty` can auto-number; otherwise the PDF shows
# `5.9.1 5.9.1 Setup` (manual prefix + arxiv.sty's auto-number).
#
# Called from `research/paper/Makefile`. Direct invocation also works:
#   bash research/scripts/regen_body_tex.sh
set -euo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")"/../.. && pwd)")
PAPER="$REPO/research/paper"
BUILD="$PAPER/arxiv-build"

# Pattern explanation:
#   ^(#+)[[:space:]]+   — the markdown heading prefix (one or more #)
#   ([0-9]+\.[0-9]+\.?| — `5.9` or `5.9.` style
#    [0-9]+\.|         —  or `5.` style
#    A\.[0-9]+\.?)      —  or `A.1` / `A.1.` style appendices
#   [[:space:]]+        — the trailing space before the section name
# Replace with `\1 ` (heading marker + single space) — section name passes
# through unchanged.
SED_PATTERN='s/^(#+)[[:space:]]+([0-9]+\.[0-9]+\.?|[0-9]+\.|A\.[0-9]+\.?)[[:space:]]+/\1 /'

for src in paper_v2_en.md paper_v2_es.md; do
    case "$src" in
        *_en.md)  out="body.tex" ;;
        *_es.md)  out="body_es.tex" ;;
    esac
    sed -E "$SED_PATTERN" "$PAPER/$src" \
        | pandoc -f markdown -t latex --columns=80 \
                 --syntax-highlighting=none \
                 -o "$BUILD/$out"
    echo "  $src → arxiv-build/$out ($(wc -c < "$BUILD/$out") bytes)"
done
