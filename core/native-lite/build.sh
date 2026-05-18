#!/usr/bin/env bash
# Build libdazzle_lite for the host platform (Linux .so, macOS .dylib,
# Windows-via-MSYS2 .dll).  Outputs land in build/ and are then staged
# into the Flutter Desktop plugin's per-platform directories.
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build
cd build

cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --config Release -j 4

# Locate the produced library.
case "$(uname -s)" in
  Darwin)  LIB="libdazzle_lite.dylib"; FLUTTER_DIR="../../../sdk/flutter/dazzle_flutter/macos/Frameworks" ;;
  Linux)   LIB="libdazzle_lite.so";    FLUTTER_DIR="../../../sdk/flutter/dazzle_flutter/linux/native" ;;
  MINGW*|MSYS*|CYGWIN*) LIB="dazzle_lite.dll"; FLUTTER_DIR="../../../sdk/flutter/dazzle_flutter/windows/native" ;;
  *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

test -f "$LIB" || { echo "ERROR: $LIB not produced"; ls; exit 1; }

echo ""
echo "Build OK:"
ls -lh "$LIB"

mkdir -p "$FLUTTER_DIR"
cp "$LIB" "$FLUTTER_DIR/"
echo ""
echo "Staged into: $FLUTTER_DIR"
