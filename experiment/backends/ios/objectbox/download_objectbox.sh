#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Fetch ObjectBox-Swift 5.3.0-beta.4: the iOS/macOS XCFramework + the
# OBXCodeGen Sourcery binary used to generate `EntityInfo.generated.swift`
# from `// objectbox: entity` annotations. Both are gitignored (the
# XCFramework is 39 MB, the Sourcery binary is 127 MB).
#
# Run from anywhere; the script resolves its own location via $0.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="5.3.0-beta.4"
URL="https://github.com/objectbox/objectbox-swift/releases/download/v${VERSION}/ObjectBox-xcframework-${VERSION}.zip"
TMP_ZIP="${HERE}/.objectbox-${VERSION}.zip"
TMP_DIR="${HERE}/.objectbox-${VERSION}"

mkdir -p "${HERE}/Frameworks"

if [[ -d "${HERE}/Frameworks/ObjectBox.xcframework" ]] && [[ -d "${HERE}/CodeGen/Mac/OBXCodeGen.framework" ]]; then
    echo "[download_objectbox] already present:"
    echo "  XCFramework: ${HERE}/Frameworks/ObjectBox.xcframework"
    echo "  CodeGen:     ${HERE}/CodeGen/Mac/OBXCodeGen.framework"
    exit 0
fi

echo "[download_objectbox] fetching ${URL}"
curl -fsSL -o "${TMP_ZIP}" "${URL}"

echo "[download_objectbox] extracting"
rm -rf "${TMP_DIR}"
unzip -q "${TMP_ZIP}" -d "${TMP_DIR}"

if [[ ! -d "${HERE}/Frameworks/ObjectBox.xcframework" ]]; then
    mv "${TMP_DIR}/ObjectBox.xcframework" "${HERE}/Frameworks/"
fi

if [[ ! -d "${HERE}/CodeGen" ]]; then
    mkdir -p "${HERE}/CodeGen"
    mv "${TMP_DIR}/Mac"             "${HERE}/CodeGen/"
    mv "${TMP_DIR}/setup.rb"        "${HERE}/CodeGen/"
    mv "${TMP_DIR}/generate_sources.sh" "${HERE}/CodeGen/"
fi

rm -rf "${TMP_DIR}" "${TMP_ZIP}"

echo "[download_objectbox] OK"
echo "  ${HERE}/Frameworks/ObjectBox.xcframework"
echo "  ${HERE}/CodeGen/Mac/OBXCodeGen.framework"
