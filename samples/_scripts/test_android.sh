#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end headless test of the three Dazzle samples on an Android
# device. For each sample:
#   1. install the debug APK
#   2. `am start` with extra `SAMPLE_TEST=1` — the Activity detects the
#      flag, wires a FakeLLMClient, runs a scripted turn, and writes
#      `sample_test_<name>.json` to the device's public Documents dir.
#   3. poll the marker file until the run completes
#   4. pull the JSON, validate pass/fail, report
#
# Exits non-zero if any sample fails.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SDK_ANDROID="$HERE/../sdk/android"
RESULTS="$HERE/_scripts/_test_results"
mkdir -p "$RESULTS"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Ensure a device is connected.
if ! adb devices | grep -q "^\S\+\sdevice$"; then
    err "no Android device connected (expected via adb)"
    exit 1
fi

DEVICE=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
log "device: $DEVICE"

FAIL=0

test_one() {
    local name="$1"  pkg="$2"  gradle_target="$3"

    log "══ $name ══"

    log "  building + installing"
    (cd "$SDK_ANDROID" && ./gradlew "$gradle_target:installDebug" \
        --quiet 2>&1 | tail -3) || { err "  install failed"; FAIL=1; return; }

    # Remove any stale JSON + marker from the app's filesDir. The
    # harness writes to app-private storage (filesDir) to avoid
    # Android 13+ scoped-storage EACCES on /sdcard/Documents.
    adb shell "run-as $pkg rm -f files/sample_test_${name}.json \
                    files/experiment_backends_complete.marker" \
        2>/dev/null || true

    log "  launching with SAMPLE_TEST=1"
    adb shell "am start -n ${pkg}/.MainActivity --es SAMPLE_TEST 1" \
        >/dev/null 2>&1 || { err "  launch failed"; FAIL=1; return; }

    # Dev smoke with FakeLLMClient; each turn is instant so 120 s
    # covers build + install + Dazzle boot + scripted turns + the
    # 5 s visible post-run banner.
    local deadline=$(($(date +%s) + 120))
    local got_marker=""
    while (( $(date +%s) < deadline )); do
        got_marker=$(adb shell "run-as $pkg cat files/experiment_backends_complete.marker 2>/dev/null" \
            2>/dev/null | tr -d '\r\n' || true)
        if [[ "$got_marker" == *"sample_test_${name}"* ]]; then
            break
        fi
        sleep 1
    done

    if [[ "$got_marker" != *"sample_test_${name}"* ]]; then
        err "  timed out waiting for marker"
        FAIL=1
        return
    fi

    log "  marker: $got_marker"

    # Pull the JSON report from the app's filesDir via run-as.
    adb shell "run-as $pkg cat files/sample_test_${name}.json" \
        > "$RESULTS/${name}_android.json" 2>/dev/null \
        || { err "  pull failed"; FAIL=1; return; }

    # Validate. We check `status` == pass AND the behavioural
    # invariants (tool reply shape, dataset content, coherent final
    # reply). status=pass alone is not enough — a crash-silenced
    # handler can still emit pass with an empty tool payload.
    local status=$(python3 -c "import json; print(json.load(open('$RESULTS/${name}_android.json'))['status'])")
    if [[ "$status" != "pass" ]]; then
        err "  status=$status (expected pass)"
        cat "$RESULTS/${name}_android.json" >&2
        FAIL=1
        return
    fi

    if ! python3 "$HERE/_scripts/validate_sample_report.py" \
            "$name" "$RESULTS/${name}_android.json"; then
        err "  behavioural validation failed"
        FAIL=1
        return
    fi

    ok "  PASS — $(python3 -c "
import json
d = json.load(open('$RESULTS/${name}_android.json'))
print(f\"{d['turn_count']} turns, {d['user_turns']}u/{d['assistant_turns']}a/{d['tool_turns']}t, {d['llm_call_count']} LLM calls, {d['elapsed_ms']}ms\")
")"
}

test_one "chat-memory" "dev.dazzle.samples.chatmemory" ":samples-chat-memory"
test_one "chat-iot"    "dev.dazzle.samples.chatiot"    ":samples-chat-iot"
test_one "chat-kb"     "dev.dazzle.samples.chatkb"     ":samples-chat-kb"

echo
if [[ $FAIL -eq 0 ]]; then
    ok "═══ ALL ANDROID SAMPLES PASSED ═══"
else
    err "═══ $FAIL ANDROID SAMPLE(S) FAILED ═══"
    exit 1
fi
