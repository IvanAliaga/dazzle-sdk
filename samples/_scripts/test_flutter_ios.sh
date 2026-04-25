#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end headless test of the three Dazzle FLUTTER samples on an
# iPhone. Mirrors test_flutter_android.sh but uses
#   flutter build ios --debug --dart-define=SAMPLE_TEST=1
#   xcrun devicectl device install / launch
# and pulls the sample_test_<name>.json from the app's Documents via
# `xcrun devicectl device copy from`.
#
# Prereq: sdk/ios/build.sh has produced Dazzle.xcframework.

set -uo pipefail   # not -e: polling loops tolerate transient cat failures.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/ivanaliaga/Documents/flutter/bin/flutter}"
RESULTS="$HERE/_scripts/_test_results"
mkdir -p "$RESULTS"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

CORE_DEVICE="${CORE_DEVICE:-7C7BF335-CC32-5A31-8686-00195459CB50}"  # iPhone 12 Pro
log "iOS device: CORE=$CORE_DEVICE"

# Free Apple Dev profile caps at 3 simultaneously-installed apps signed
# by the same team. Uninstall stale dev-signed Dazzle apps first.
for stale in \
    io.dazzle.experiment.backends \
    io.dazzle.experiment \
    io.dazzle.experiment.storage \
    io.dazzle.experiment.multiagent \
    io.dazzle.samples.chatmemory \
    io.dazzle.samples.chatiot \
    io.dazzle.samples.chatkb \
    dev.dazzle.samples.dazzleChatMemoryFlutter \
    dev.dazzle.samples.dazzleChatIotFlutter \
    dev.dazzle.samples.dazzleChatKbFlutter; do
    xcrun devicectl device uninstall app --device "$CORE_DEVICE" "$stale" \
        2>/dev/null >/dev/null || true
done

FAIL=0

test_one() {
    local name="$1"
    local app_dir="$HERE/${name}-flutter"
    # Flutter's pbxproj bundle ID: dev.dazzle.samples.dazzleChat<Kind>Flutter
    local kind
    case "$name" in
        chat-memory) kind="Memory" ;;
        chat-iot)    kind="Iot"    ;;
        chat-kb)     kind="Kb"     ;;
        *)           err "unknown sample $name"; return 1 ;;
    esac
    local bundle_id="dev.dazzle.samples.dazzleChat${kind}Flutter"

    log "══ ${name}-flutter ══  ($bundle_id)"

    log "  clearing stale Pods cache"
    rm -rf "$app_dir/ios/Pods" "$app_dir/ios/Podfile.lock"

    log "  building iOS Runner.app (release — JIT blocked on iOS)"
    # iOS disallows JIT for security, so Flutter debug (JIT) apps launched
    # standalone crash with signal 11. We build `--release` (AOT) so the
    # headless harness can launch without a Flutter tool VM attached.
    (cd "$app_dir" && "$FLUTTER" build ios --release \
        --dart-define=SAMPLE_TEST=1 2>&1 | tail -5) \
        || { err "  flutter build failed"; FAIL=1; return; }

    local app_path="$app_dir/build/ios/iphoneos/Runner.app"
    if [[ -z "$app_path" ]]; then
        err "  Runner.app not found under DerivedData"
        FAIL=1
        return
    fi
    log "  installing $app_path"
    xcrun devicectl device install app --device "$CORE_DEVICE" "$app_path" \
        >/dev/null 2>&1 \
        || { err "  devicectl install failed"; FAIL=1; return; }

    log "  launching"
    xcrun devicectl device process launch \
        --device "$CORE_DEVICE" \
        --terminate-existing \
        --environment-variables '{"DAZZLE_SAMPLE_TEST":"1"}' \
        "$bundle_id" >/dev/null 2>&1 \
        || { err "  launch failed (device locked/trust?)"; FAIL=1; return; }

    # Poll Documents for sample_test_<name>.json.
    # Test mode renders the chat live + holds a ~5s post-run banner.
    local deadline=$(($(date +%s) + 150))
    local pulled=""
    while (( $(date +%s) < deadline )); do
        local tmp
        tmp=$(mktemp -d)
        if xcrun devicectl device copy from \
            --device "$CORE_DEVICE" \
            --domain-type appDataContainer \
            --domain-identifier "$bundle_id" \
            --source Documents \
            --destination "$tmp" >/dev/null 2>&1; then
            local root="$tmp"
            [[ -d "$tmp/Documents" ]] && root="$tmp/Documents"
            if [[ -f "$root/sample_test_${name}.json" ]]; then
                pulled="$root/sample_test_${name}.json"
                cp "$pulled" "$RESULTS/${name}_flutter_ios.json"
                rm -rf "$tmp"
                break
            fi
        fi
        rm -rf "$tmp"
        sleep 3
    done

    if [[ -z "$pulled" ]]; then
        err "  timed out waiting for sample_test_${name}.json"
        FAIL=1
        return
    fi

    local status
    status=$(python3 -c "import json; print(json.load(open('$RESULTS/${name}_flutter_ios.json'))['status'])" 2>/dev/null)
    if [[ "$status" != "pass" ]]; then
        err "  status=$status"
        cat "$RESULTS/${name}_flutter_ios.json" >&2
        FAIL=1
        return
    fi

    if ! python3 "$HERE/_scripts/validate_sample_report.py" \
            "$name" "$RESULTS/${name}_flutter_ios.json"; then
        err "  behavioural validation failed"
        FAIL=1
        return
    fi

    ok "  PASS — $(python3 -c "
import json
d = json.load(open('$RESULTS/${name}_flutter_ios.json'))
print(f\"{d['turn_count']} turns, {d['user_turns']}u/{d['assistant_turns']}a/{d['tool_turns']}t, {d['llm_call_count']} LLM calls, {d['elapsed_ms']}ms\")
")"

    # Free Apple Dev profile cap: uninstall so the next sample has a slot.
    xcrun devicectl device uninstall app --device "$CORE_DEVICE" \
        "$bundle_id" 2>/dev/null >/dev/null || true
}

test_one "chat-memory"
test_one "chat-iot"
test_one "chat-kb"

echo
if [[ $FAIL -eq 0 ]]; then
    ok "═══ ALL FLUTTER iOS SAMPLES PASSED ═══"
else
    err "═══ $FAIL FLUTTER iOS SAMPLE(S) FAILED ═══"
    exit 1
fi
