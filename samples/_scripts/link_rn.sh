#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Prepare the dazzle-react-native package for a local RN app build.
# Mirror of samples/_scripts/link_flutter.sh:
#   - Android: publish the Dazzle AAR to the in-tree file-URL maven repo
#     (sdk/android/build/maven-repo) so the RN plugin's
#     `implementation "dev.dazzle:dazzle-sdk:<version>"` resolves.
#   - iOS: rsync sdk/ios/Sources + cshim + xcframework's
#     libvalkey-server.a into ios/vendored/ so CocoaPods' source_files
#     can reach them (pods only look inside the pod dir).
#
# Run once after cloning, and whenever the native SDK changes.
#
# Usage:
#   samples/_scripts/link_rn.sh          # all
#   samples/_scripts/link_rn.sh android
#   samples/_scripts/link_rn.sh ios

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SDK_ANDROID="$HERE/sdk/android"
SDK_IOS="$HERE/sdk/ios"
PLUGIN_IOS="$HERE/sdk/react-native/dazzle-react-native/ios"
MAVEN_REPO="$SDK_ANDROID/build/maven-repo"
XCFW_SRC="$SDK_IOS/Dazzle.xcframework"

TARGET="${1:-all}"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

link_android() {
    log "publishing Dazzle AAR to local maven-repo"
    (cd "$SDK_ANDROID" && ./gradlew --quiet \
        publishDebugPublicationToLocalFileRepoRepository \
        publishReleasePublicationToLocalFileRepoRepository \
        2>&1 | tail -5)
    if [[ ! -d "$MAVEN_REPO/dev/dazzle/dazzle-sdk" ]]; then
        err "Maven artefacts not found under $MAVEN_REPO after publish"
        exit 1
    fi
    ok "published dev.dazzle:dazzle-sdk:* to $MAVEN_REPO"
}

link_ios() {
    log "building Dazzle.xcframework (iOS)"
    if [[ ! -d "$XCFW_SRC" ]] || [[ -z "$(ls "$XCFW_SRC" 2>/dev/null)" ]]; then
        (cd "$SDK_IOS" && ./build.sh)
    fi
    if [[ ! -d "$XCFW_SRC" ]] || [[ -z "$(ls "$XCFW_SRC" 2>/dev/null)" ]]; then
        err "xcframework not found at $XCFW_SRC after build"
        exit 1
    fi

    # Preserve hand-authored module.modulemap if present so we don't
    # stomp a richer version.
    local VENDOR_DIR="$PLUGIN_IOS/vendored"
    local MODMAP="$VENDOR_DIR/include/module.modulemap"
    local KEEP_MODMAP=""
    [[ -f "$MODMAP" ]] && KEEP_MODMAP="$(cat "$MODMAP")"

    log "vendoring Swift sources + cshim into $VENDOR_DIR"
    rm -rf "$VENDOR_DIR"
    mkdir -p "$VENDOR_DIR/Sources" "$VENDOR_DIR/include" \
             "$VENDOR_DIR/lib/ios-arm64"
    rsync -a --delete "$SDK_IOS/Sources/" "$VENDOR_DIR/Sources/"
    cp "$SDK_IOS/cshim/dazzle_ios.c"            "$VENDOR_DIR/"
    cp "$SDK_IOS/cshim/include/dazzle_ios.h"    "$VENDOR_DIR/include/"
    cp "$XCFW_SRC/ios-arm64/Headers/"*.h        "$VENDOR_DIR/include/" 2>/dev/null || true
    cp "$XCFW_SRC/ios-arm64/libvalkey-server.a" "$VENDOR_DIR/lib/ios-arm64/"

    if [[ -n "$KEEP_MODMAP" ]]; then
        printf '%s\n' "$KEEP_MODMAP" > "$MODMAP"
    else
        cat > "$MODMAP" <<'MODMAP'
module DazzleC {
    header "dazzle_ios.h"
    header "dazzle_vs.h"
    header "dazzle_llama.h"
    export *
}
MODMAP
    fi
    ok "$(basename "$XCFW_SRC") vendored; Swift source count: $(find "$VENDOR_DIR" -name '*.swift' | wc -l | tr -d ' ')"
}

case "$TARGET" in
    all)     link_android; link_ios ;;
    android) link_android ;;
    ios)     link_ios ;;
    *)       err "unknown target '$TARGET' — use: all | android | ios"; exit 1 ;;
esac

ok "React Native linking ready. Now: cd samples/chat-memory-rn && npm run ios|android"
