#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Prepare the Flutter plugin for a local `flutter run` / `flutter build`.
# Builds the native artefacts (Android AAR + iOS xcframework) if they're
# missing or stale, then drops the Android AAR into the plugin's
# `android/libs/` so the plugin's `implementation(name:'dazzle', ...)`
# resolves. iOS already consumes `sdk/ios/Dazzle.xcframework` directly
# via the podspec — no copy step needed.
#
# Run once after cloning, and whenever the native SDK changes.
#
# Usage:
#   samples/_scripts/link_flutter.sh             # full: Android + iOS
#   samples/_scripts/link_flutter.sh android     # Android only
#   samples/_scripts/link_flutter.sh ios         # iOS only

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SDK_ANDROID="$HERE/sdk/android"
SDK_IOS="$HERE/sdk/ios"
MAVEN_REPO="$SDK_ANDROID/build/maven-repo"
XCFW_SRC="$SDK_IOS/Dazzle.xcframework"

TARGET="${1:-all}"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

link_android() {
    log "publishing Dazzle AAR to local maven-repo (Android)"
    (cd "$SDK_ANDROID" && ./gradlew --quiet \
        publishDebugPublicationToLocalFileRepoRepository \
        publishReleasePublicationToLocalFileRepoRepository \
        2>&1 | tail -5)
    if [[ ! -d "$MAVEN_REPO/dev/dazzle/dazzle-sdk" ]]; then
        err "Maven artefacts not found under $MAVEN_REPO after publish"
        exit 1
    fi
    ok "published com.ivanaliaga:dazzle-sdk:* to $MAVEN_REPO"
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

    # Vendor the Swift + C shim sources into the plugin's pod dir.
    # CocoaPods requires `source_files` to live inside the pod root, so
    # we rsync them on each relink.
    local PLUGIN_IOS="$HERE/sdk/flutter/dazzle_flutter/ios"
    local VENDOR_DIR="$PLUGIN_IOS/Classes/vendored"
    log "vendoring Swift sources + cshim into $VENDOR_DIR"
    # Preserve an existing hand-authored module.modulemap so we don't
    # overwrite it with a stale version from the xcframework headers.
    local MODMAP="$PLUGIN_IOS/Classes/vendored/include/module.modulemap"
    local KEEP_MODMAP=""
    if [[ -f "$MODMAP" ]]; then
        KEEP_MODMAP="$(cat "$MODMAP")"
    fi
    rm -rf "$VENDOR_DIR"
    mkdir -p "$VENDOR_DIR/Sources" "$VENDOR_DIR/include"
    rsync -a --delete "$SDK_IOS/Sources/" "$VENDOR_DIR/Sources/"
    cp "$SDK_IOS/cshim/dazzle_ios.c"            "$VENDOR_DIR/"
    cp "$SDK_IOS/cshim/include/dazzle_ios.h"    "$VENDOR_DIR/include/"
    # Pull the C headers the xcframework exposes (dazzle_vs.h,
    # dazzle_llama.h) into the same include dir so `import DazzleC`
    # sees the whole surface.
    cp "$XCFW_SRC/ios-arm64/Headers/"*.h "$VENDOR_DIR/include/" 2>/dev/null || true
    # Copy the static archive inside the plugin so the linker path
    # resolves cleanly through Flutter's .symlinks/plugins/ layout.
    mkdir -p "$VENDOR_DIR/lib/ios-arm64" "$VENDOR_DIR/lib/ios-arm64-simulator"
    cp "$XCFW_SRC/ios-arm64/libvalkey-server.a" \
       "$VENDOR_DIR/lib/ios-arm64/libvalkey-server.a"
    cp "$XCFW_SRC/ios-arm64-simulator/libvalkey-server.a" \
       "$VENDOR_DIR/lib/ios-arm64-simulator/libvalkey-server.a" 2>/dev/null || true
    # Restore (or write a fresh default) the DazzleC modulemap.
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

    ok "$(basename "$XCFW_SRC") present at $XCFW_SRC"
    ok "  Swift sources vendored: $(find "$VENDOR_DIR" -name '*.swift' | wc -l | tr -d ' ') files"
}

case "$TARGET" in
    all)
        link_android
        link_ios
        ;;
    android)
        link_android
        ;;
    ios)
        link_ios
        ;;
    *)
        err "unknown target '$TARGET' — use: all | android | ios"
        exit 1
        ;;
esac

ok "Flutter linking ready. Now: cd samples/chat-memory-flutter && flutter run"
