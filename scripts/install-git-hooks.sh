#!/bin/bash
# Installation script for no-LLM-attribution commit hooks

set -e

cd "$(git rev-parse --show-toplevel)"

# Make hooks executable
chmod +x .githooks/commit-msg .githooks/pre-push

# Install hooks (idempotent)
if ! git config --local core.hooksPath | grep -q ".githooks"; then
    git config --local core.hooksPath .githooks
fi

# Self-test: try to commit a message with prohibited pattern
TEST_MSG="Test

Co-Authored-By: Claude <noreply@anthropic.com>"

TEMP_FILE=$(mktemp)
echo "$TEST_MSG" > "$TEMP_FILE"

if .githooks/commit-msg "$TEMP_FILE" 2>/dev/null; then
    # Hook accepted forbidden message — installation is broken
    rm -f "$TEMP_FILE"
    echo "⚠️  WARNING: Hook installation may be broken (rejected test with prohibited pattern)"
    exit 2
fi

rm -f "$TEMP_FILE"

echo "✅ Git hooks installed successfully"
echo "   Location: .githooks/ (tracked in repo)"
echo "   Config: core.hooksPath = .githooks"
echo ""
echo "The following protections are now active:"
echo "  • commit-msg: Rejects commits with LLM attribution on commit"
echo "  • pre-push: Rejects pushes with LLM attribution in any commit"
echo ""
echo "For more info, see: docs/COMMIT_POLICY.md"
