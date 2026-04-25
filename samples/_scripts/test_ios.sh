#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end headless test of the three Dazzle samples on an iPhone.
# Mirrors `test_android.sh` but drives xcodebuild + xcrun devicectl.
#
# For each sample:
#   1. xcodegen + xcodebuild install to the device (handles code-signing
#      + provisioning via -allowProvisioningUpdates)
#   2. Launch with env SAMPLE_TEST=1 — the App detects this, swaps
#      ChatView for SampleTestRunnerView, runs the scripted flow with
#      FakeLLMClient, writes sample_test_<name>.json to Documents, and
#      exits with exit(0) / exit(1).
#   3. Poll the marker file on the device (re-pulled each tick because
#      iOS doesn't expose the sandbox directly).
#   4. Pull the JSON, validate pass/fail, report.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$HERE/_scripts/_test_results"
mkdir -p "$RESULTS"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# xcodebuild and devicectl use DIFFERENT device identifiers for the
# same iPhone:
#   - HW_UUID     (xcodebuild `-destination "id=..."`): from `xctrace list devices`
#   - CORE_DEVICE (devicectl `--device ...`):           from `devicectl list devices`
HW_UUID="${HW_UUID:-00008101-00115DD93E44001E}"      # iPhone 12 Pro, xctrace id
CORE_DEVICE="${CORE_DEVICE:-7C7BF335-CC32-5A31-8686-00195459CB50}"  # iPhone 12 Pro, devicectl id
log "iOS device: HW=$HW_UUID, CORE=$CORE_DEVICE"

# Free Apple Dev profiles cap a device at 3 simultaneously-installed
# apps signed by the same team. Uninstall any prior dev-signed Dazzle
# app (benchmarks, old sample revisions) to free slots for the three
# samples below. A paid dev seat removes the cap.
for stale in io.dazzle.experiment.backends io.dazzle.experiment \
             io.dazzle.experiment.storage io.dazzle.experiment.multiagent; do
    xcrun devicectl device uninstall app --device "$CORE_DEVICE" "$stale" \
        2>/dev/null >/dev/null || true
done

FAIL=0

test_one() {
    local name="$1"  bundle_id="$2"  ios_dir="$3"  xproj="$4"  scheme="$5"

    log "══ $name ══"

    # Ensure xcodeproj exists.
    if [[ ! -d "$HERE/$ios_dir/$xproj" ]]; then
        log "  regenerating $xproj"
        (cd "$HERE/$ios_dir" && xcodegen generate >/dev/null 2>&1) \
            || { err "  xcodegen failed"; FAIL=1; return; }
    fi

    log "  building + installing on device"
    (cd "$HERE/$ios_dir" && \
        xcodebuild -project "$xproj" -scheme "$scheme" \
            -destination "id=$HW_UUID" \
            -configuration Debug \
            -allowProvisioningUpdates \
            build install 2>&1 | tail -5) >/dev/null \
        || { err "  build/install failed"; FAIL=1; return; }

    # Install via devicectl too — some iOS versions need a second push.
    local APP_DIR=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*$scheme*/Build/Products/Debug-iphoneos/$scheme.app" -type d 2>/dev/null | head -1)
    if [[ -n "$APP_DIR" ]]; then
        xcrun devicectl device install app --device "$CORE_DEVICE" "$APP_DIR" \
            >/dev/null 2>&1 || true
    fi

    log "  launching with SAMPLE_TEST=1"
    xcrun devicectl device process launch \
        --device "$CORE_DEVICE" \
        --terminate-existing \
        --environment-variables '{"SAMPLE_TEST":"1"}' \
        "$bundle_id" >/dev/null 2>&1 \
        || { err "  launch failed (device locked / trust?)"; FAIL=1; return; }

    # Poll Documents for the sample_test_<name>.json file.
    # Test mode now renders the chat live + holds a ~5s post-run banner
    # so a viewer can confirm the conversation played out visually.
    local deadline=$(($(date +%s) + 150))
    local pulled=""
    while (( $(date +%s) < deadline )); do
        local tmp=$(mktemp -d)
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
                cp "$pulled" "$RESULTS/${name}_ios.json"
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
    status=$(python3 -c "import json; print(json.load(open('$RESULTS/${name}_ios.json'))['status'])")
    if [[ "$status" != "pass" ]]; then
        err "  status=$status"
        cat "$RESULTS/${name}_ios.json" >&2
        FAIL=1
        return
    fi

    if ! python3 "$HERE/_scripts/validate_sample_report.py" \
            "$name" "$RESULTS/${name}_ios.json"; then
        err "  behavioural validation failed"
        FAIL=1
        return
    fi

    ok "  PASS — $(python3 -c "
import json
d = json.load(open('$RESULTS/${name}_ios.json'))
print(f\"{d['turnCount']} turns, {d['userTurns']}u/{d['assistantTurns']}a/{d['toolTurns']}t, {d['llmCallCount']} LLM calls, {d['elapsedMs']}ms\")
")"
}

test_one "chat-memory" "io.dazzle.samples.chatmemory" "chat-memory/ios" "DazzleChatMemory.xcodeproj" "DazzleChatMemory"
test_one "chat-iot"    "io.dazzle.samples.chatiot"    "chat-iot/ios"    "DazzleChatIot.xcodeproj"    "DazzleChatIot"
test_one "chat-kb"     "io.dazzle.samples.chatkb"     "chat-kb/ios"     "DazzleChatKb.xcodeproj"     "DazzleChatKb"

echo
if [[ $FAIL -eq 0 ]]; then
    ok "═══ ALL iOS SAMPLES PASSED ═══"
else
    err "═══ $FAIL iOS SAMPLE(S) FAILED ═══"
    exit 1
fi
