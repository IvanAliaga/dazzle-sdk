#!/usr/bin/env bash
# Build dazzle.wasm + dazzle.js for Flutter Web / RN Web.
# Outputs land in build/ and are copied into both consuming SDKs.
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build
cd build

emcmake cmake -DCMAKE_BUILD_TYPE=Release ..
emmake make -j4

# Verify outputs.
test -f dazzle.js   || { echo "ERROR: dazzle.js not produced"; exit 1; }
test -f dazzle.wasm || { echo "ERROR: dazzle.wasm not produced"; exit 1; }

echo ""
echo "Build OK:"
ls -lh dazzle.js dazzle.wasm

# Copy into both SDK packages so Flutter Web / RN Web can serve them as
# static assets without a separate publish step.
FLUTTER_WEB_DIR="../../../sdk/flutter/dazzle_flutter/web/native"
RN_WEB_DIR="../../../sdk/react-native/dazzle-react-native/web/native"
mkdir -p "$FLUTTER_WEB_DIR" "$RN_WEB_DIR"
cp dazzle.js   "$FLUTTER_WEB_DIR/"
cp dazzle.wasm "$FLUTTER_WEB_DIR/"
cp dazzle.js   "$RN_WEB_DIR/"
cp dazzle.wasm "$RN_WEB_DIR/"

echo ""
echo "Staged into:"
echo "  $FLUTTER_WEB_DIR"
echo "  $RN_WEB_DIR"
