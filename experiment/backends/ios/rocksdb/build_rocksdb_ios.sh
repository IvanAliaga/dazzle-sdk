#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Rebuilds RocksDB.xcframework from source for iOS device + simulator.
# Mirrors the CMake flag set used by the Android NDK build (cpp/CMakeLists.txt)
# so the engine compiles with the same feature surface on both platforms:
# no compression libs, no JNI, RTTI on, portable mode.
#
# The xcframework is gitignored — re-run this script after a fresh checkout
# (or after bumping ROCKSDB_TAG) to regenerate it.

set -euo pipefail

ROCKSDB_TAG="${ROCKSDB_TAG:-v9.10.0}"
TMP_DIR="${TMP_DIR:-/tmp}"
SRC_DIR="$TMP_DIR/rocksdb-src-$ROCKSDB_TAG"
BUILD_DEV="$TMP_DIR/rocksdb-build-device-$ROCKSDB_TAG"
BUILD_SIM="$TMP_DIR/rocksdb-build-sim-$ROCKSDB_TAG"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OUT="$SCRIPT_DIR/RocksDB.xcframework"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "[rocksdb_ios] cloning $ROCKSDB_TAG → $SRC_DIR"
  git clone --depth=1 --branch "$ROCKSDB_TAG" \
    https://github.com/facebook/rocksdb.git "$SRC_DIR"
fi

CMAKE_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
  -DROCKSDB_BUILD_SHARED=OFF
  -DWITH_TESTS=OFF -DWITH_TOOLS=OFF -DWITH_BENCHMARK_TOOLS=OFF
  -DWITH_CORE_TOOLS=OFF -DWITH_ALL_TESTS=OFF
  -DWITH_GFLAGS=OFF -DWITH_SNAPPY=OFF -DWITH_LZ4=OFF -DWITH_ZLIB=OFF
  -DWITH_ZSTD=OFF -DWITH_BZ2=OFF -DWITH_JEMALLOC=OFF
  -DPORTABLE=ON -DUSE_RTTI=ON -DWITH_JNI=OFF -DWITH_TRACE_TOOLS=OFF
  -DFAIL_ON_WARNINGS=OFF
)

echo "[rocksdb_ios] configuring device build"
cmake -B "$BUILD_DEV" -S "$SRC_DIR" \
  -DCMAKE_OSX_SYSROOT=iphoneos "${CMAKE_FLAGS[@]}" >/dev/null

echo "[rocksdb_ios] configuring simulator build"
cmake -B "$BUILD_SIM" -S "$SRC_DIR" \
  -DCMAKE_OSX_SYSROOT=iphonesimulator "${CMAKE_FLAGS[@]}" >/dev/null

echo "[rocksdb_ios] building device + sim in parallel (~5 min)"
cmake --build "$BUILD_DEV" --target rocksdb -j 8 --config Release &
PID_DEV=$!
cmake --build "$BUILD_SIM" --target rocksdb -j 8 --config Release &
PID_SIM=$!
wait $PID_DEV $PID_SIM

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$BUILD_DEV/librocksdb.a" -headers "$SRC_DIR/include" \
  -library "$BUILD_SIM/librocksdb.a" -headers "$SRC_DIR/include" \
  -output "$OUT"

echo "[rocksdb_ios] xcframework written: $OUT"
du -sh "$OUT"
