#!/usr/bin/env bash
# Confidentiality pre-commit hook for the public dazzle SDK family of
# repos. Blocks `git commit` if any staged file contains a forbidden
# customer-track string. The same pattern list is mirrored to the
# CI workflow .github/workflows/confidentiality-scan.yml so what
# blocks locally also blocks on push.
#
# Install in a repo:
#
#   cp scripts/pre-commit-confidentiality.sh .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
#
# Bypass (emergency only, requires explicit env var to discourage):
#
#   ALLOW_CONFIDENTIAL=1 git commit -m "..."
#
# Adding a new term: edit FORBIDDEN below AND the CI workflow file.

set -euo pipefail

if [ "${ALLOW_CONFIDENTIAL:-0}" = "1" ]; then
    echo "pre-commit: ALLOW_CONFIDENTIAL=1 — bypassing confidentiality scan"
    exit 0
fi

FORBIDDEN=(
    'esas[-_]api'
    'ESAS[-_]?Prolog'
    'hetzner[- _]?cax'
    '\bCAX11\b'
    'Ampere Altra'
    'aarch64-linux-gnu'
    'linux-aarch64-gnu'
    'dazzle_runtime_(start|stop|status)'
    'DAZZLE_STATIC[^_]'
    'libdazzle\.(a|so)\b'
    '06_linux_main_rename'
    'apply_patches_linux'
    'release-aarch64-linux-gnu'
    'Sprint[- ]?6'
    '1\.0\.0-rc\.1'
    'ToolContext cache layer'
    'replacing OpenAI for cost'
)

# Files staged for commit (added or modified), excluding deletions.
mapfile -t STAGED < <(git diff --cached --name-only --diff-filter=ACMR)

if [ ${#STAGED[@]} -eq 0 ]; then
    exit 0
fi

fail=0
for pat in "${FORBIDDEN[@]}"; do
    # `git diff --cached -G` matches if the regex appears in any
    # added or removed line of the staged hunks. Combined with the
    # file list, we get only the staged content (not the existing
    # tree).
    matches=$(git diff --cached -G "$pat" --name-only -- "${STAGED[@]}" 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo "pre-commit: forbidden pattern '$pat' in staged content:"
        echo "$matches" | sed 's/^/  /'
        fail=1
    fi
done

if [ "$fail" -eq 1 ]; then
    echo
    echo "Commit blocked by confidentiality pre-commit hook."
    echo "Remove the forbidden strings from staged files, or — if the"
    echo "match is a legitimate false-positive — adjust the regex in:"
    echo "  $(git rev-parse --git-dir)/hooks/pre-commit"
    echo "  .github/workflows/confidentiality-scan.yml"
    echo
    echo "Emergency bypass (use with care, requires explicit opt-in):"
    echo "  ALLOW_CONFIDENTIAL=1 git commit ..."
    exit 1
fi

exit 0
