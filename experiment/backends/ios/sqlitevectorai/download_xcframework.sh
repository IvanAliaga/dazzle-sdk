#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Fetch SQLiteAI's sqlite-vector xcframework for the iOS vector bench.
# The binary is Elastic License 2.0 — benchmark-only, NOT redistributed
# as part of this repo, so we pull it on demand from the upstream release.
#
# Run once before opening the iOS DazzleBackends app:
#   experiment/backends/ios/sqlitevectorai/download_xcframework.sh
#
# Pinned to the version we validated against. Bump both the URL and the
# SHA-256 in lockstep.

set -euo pipefail

VERSION="0.9.95"
SHA256="db4a3a733ff6d719c18a4692b5cbab80327daff004d8199cb53a198cb5072e85"
URL="https://github.com/sqliteai/sqlite-vector/releases/download/${VERSION}/vector-apple-xcframework-${VERSION}.zip"

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/vector.xcframework"

if [[ -d "$TARGET" ]]; then
    echo "[svai] $TARGET already exists — skipping download."
    echo "      Remove it to force a re-download."
    exit 0
fi

TMP=$(mktemp -t svec_xcf.XXXXXX).zip
echo "[svai] downloading $URL"
curl -fsSL "$URL" -o "$TMP"

# Checksum guard — refuse to extract if the byte-for-byte binary drifts.
ACTUAL=$(shasum -a 256 "$TMP" | awk '{print $1}')
if [[ "$ACTUAL" != "$SHA256" ]]; then
    echo "[svai] SHA-256 mismatch"
    echo "       expected: $SHA256"
    echo "       actual:   $ACTUAL"
    rm -f "$TMP"
    exit 1
fi
echo "[svai] sha256 ok"

unzip -q "$TMP" -d "$HERE"
rm -f "$TMP"
echo "[svai] extracted → $TARGET"
