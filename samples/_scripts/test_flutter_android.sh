#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end headless test of the three Dazzle FLUTTER samples on an
# Android device. For each sample:
#   1. `flutter build apk --debug` with SAMPLE_TEST=1 baked in via
#      --dart-define
#   2. `adb install` the APK
#   3. `adb shell am start` the main activity
#   4. poll the marker file until the run completes
#   5. pull the JSON report, validate pass/fail, print a one-line summary
#
# Exits non-zero if any sample fails.

set -uo pipefail   # not -e: we want to keep polling even when `adb shell cat` exits non-zero mid-loop.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/ivanaliaga/Documents/flutter/bin/flutter}"
ADB="${ADB:-adb}"
RESULTS="$HERE/_scripts/_test_results"
mkdir -p "$RESULTS"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

if ! "$ADB" devices | grep -q "^\S\+\sdevice$"; then
    err "no Android device connected (expected via adb)"
    exit 1
fi
DEVICE=$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')
log "device: $DEVICE"

FAIL=0

test_one() {
    local name="$1"
    local app_dir="$HERE/${name}-flutter"
    local pkg="dev.dazzle.samples.dazzle_${name//-/_}_flutter"
    local apk="$app_dir/build/app/outputs/flutter-apk/app-debug.apk"

    log "══ ${name}-flutter ══"

    log "  building APK with SAMPLE_TEST=1"
    (cd "$app_dir" && "$FLUTTER" build apk --debug \
        --dart-define=SAMPLE_TEST=1 2>&1 | tail -3) \
        || { err "  build failed"; FAIL=1; return; }

    log "  installing"
    "$ADB" install -r -t "$apk" >/dev/null 2>&1 \
        || { err "  install failed"; FAIL=1; return; }

    # Remove any stale JSON + marker from prior runs. Flutter's
    # path_provider `getApplicationDocumentsDirectory()` on Android is
    # `app_flutter/` inside the package sandbox, NOT `files/`.
    "$ADB" shell "run-as $pkg rm -f app_flutter/sample_test_${name}.json \
                                       app_flutter/experiment_backends_complete.marker" \
        2>/dev/null || true

    log "  launching"
    "$ADB" shell "am start -n ${pkg}/.MainActivity" \
        >/dev/null 2>&1 || { err "  launch failed"; FAIL=1; return; }

    # Dev smoke with FakeLLMClient; 120 s covers build + install +
    # scripted turns + the 5 s visible post-run banner.
    local deadline=$(($(date +%s) + 120))
    local got=""
    while (( $(date +%s) < deadline )); do
        got=$("$ADB" shell "run-as $pkg cat app_flutter/experiment_backends_complete.marker 2>/dev/null" \
            2>/dev/null | tr -d '\r\n' || true)
        if [[ "$got" == *"sample_test_${name}"* ]]; then break; fi
        sleep 1
    done

    if [[ "$got" != *"sample_test_${name}"* ]]; then
        err "  timed out waiting for marker (last: $got)"
        FAIL=1
        return
    fi

    log "  marker: $got"

    local out="$RESULTS/${name}_flutter_android.json"
    "$ADB" shell "run-as $pkg cat app_flutter/sample_test_${name}.json" \
        > "$out" 2>/dev/null \
        || { err "  pull failed"; FAIL=1; return; }

    local status
    status=$(python3 -c "import json; print(json.load(open('$out'))['status'])" 2>/dev/null \
        || echo "invalid")
    if [[ "$status" != "pass" ]]; then
        err "  status=$status (expected pass)"
        cat "$out" >&2
        FAIL=1
        return
    fi

    if ! python3 "$HERE/_scripts/validate_sample_report.py" \
            "$name" "$out"; then
        err "  behavioural validation failed"
        FAIL=1
        return
    fi

    ok "  PASS — $(python3 -c "
import json
d = json.load(open('$out'))
print(f\"{d['turn_count']} turns, {d['user_turns']}u/{d['assistant_turns']}a/{d['tool_turns']}t, {d['llm_call_count']} LLM calls, {d['elapsed_ms']}ms\")
")"
}

# Export FLUTTER_SAMPLES="chat-iot chat-kb" to run a subset; unset
# runs all three. Matches the selection idiom in test_rn_ios.sh.
if [[ -z "${FLUTTER_SAMPLES:-}" ]]; then
    test_one "chat-memory"
    test_one "chat-iot"
    test_one "chat-kb"
else
    for s in $FLUTTER_SAMPLES; do test_one "$s"; done
fi

echo
if [[ $FAIL -eq 0 ]]; then
    ok "═══ ALL FLUTTER ANDROID SAMPLES PASSED ═══"
else
    err "═══ $FAIL FLUTTER ANDROID SAMPLE(S) FAILED ═══"
    exit 1
fi
