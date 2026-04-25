#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end headless test of the React Native samples on Android.
# Parallel of test_flutter_android.sh but drives `npx react-native
# build-android` + adb install + shell am start.
#
# For each sample:
#   1. npm install (picks up the dazzle-react-native path dep)
#   2. build-android → APK
#   3. adb install
#   4. `am start --es DAZZLE_SAMPLE_TEST 1` — the Activity forwards the
#      extra into a System.setProperty("DAZZLE_SAMPLE_TEST", "1") call
#      before the JS bundle loads.
#   5. poll app_flutter-equivalent (`files/`) for the marker + JSON
#   6. validate status=pass
#
# Exits non-zero if any sample fails.

set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-adb}"
NODE_BIN="$(dirname "$(which node)")"
export PATH="$NODE_BIN:$PATH"
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
    local app_dir="$HERE/${name}-rn"
    # RN bundle id normalisation: dashes removed, lowercased.
    local pkg="dev.dazzle.samples.dazzle$(echo "$name" | tr -d '-')rn"
    local apk="$app_dir/android/app/build/outputs/apk/debug/app-debug.apk"

    log "══ ${name}-rn ══  ($pkg)"

    log "  npm install"
    (cd "$app_dir" && npm install --no-audit --no-fund 2>&1 | tail -3) \
        || { err "  npm install failed"; FAIL=1; return; }

    log "  pre-bundling JS (so the debug APK is standalone, no Metro)"
    mkdir -p "$app_dir/android/app/src/main/assets" \
             "$app_dir/android/app/src/main/res"
    (cd "$app_dir" && npx react-native bundle \
        --platform android \
        --dev false \
        --entry-file index.js \
        --bundle-output android/app/src/main/assets/index.android.bundle \
        --assets-dest android/app/src/main/res/ 2>&1 | tail -3) \
        || { err "  bundle failed"; FAIL=1; return; }

    log "  build-android"
    (cd "$app_dir/android" && ./gradlew assembleDebug 2>&1 | tail -5) \
        || { err "  build failed"; FAIL=1; return; }

    if [[ ! -f "$apk" ]]; then
        err "  APK not found at $apk"
        FAIL=1; return
    fi

    log "  installing"
    "$ADB" install -r -t "$apk" >/dev/null 2>&1 \
        || { err "  install failed"; FAIL=1; return; }

    "$ADB" shell "run-as $pkg rm -f files/sample_test_${name}.json \
                                      files/experiment_backends_complete.marker" \
        2>/dev/null || true

    log "  launching (DAZZLE_SAMPLE_TEST=1)"
    "$ADB" shell "am start -n ${pkg}/.MainActivity \
                 --es DAZZLE_SAMPLE_TEST 1" >/dev/null 2>&1 \
        || { err "  launch failed"; FAIL=1; return; }

    # Dev smoke with FakeLLMClient; 120 s covers build + install +
    # scripted turns + the visible post-run banner.
    local deadline=$(($(date +%s) + 120))
    local got=""
    while (( $(date +%s) < deadline )); do
        got=$("$ADB" shell "run-as $pkg cat files/experiment_backends_complete.marker 2>/dev/null" \
            2>/dev/null | tr -d '\r\n' || true)
        if [[ "$got" == *"sample_test_${name}"* ]]; then break; fi
        sleep 2
    done

    if [[ "$got" != *"sample_test_${name}"* ]]; then
        err "  timed out waiting for marker (last: $got)"
        FAIL=1
        return
    fi

    log "  marker: $got"

    local out="$RESULTS/${name}_rn_android.json"
    "$ADB" shell "run-as $pkg cat files/sample_test_${name}.json" \
        > "$out" 2>/dev/null \
        || { err "  pull failed"; FAIL=1; return; }

    local status
    status=$(python3 -c "import json; print(json.load(open('$out'))['status'])" 2>/dev/null \
        || echo "invalid")
    if [[ "$status" != "pass" ]]; then
        err "  status=$status"
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

test_one "chat-memory"
test_one "chat-iot"
test_one "chat-kb"

echo
if [[ $FAIL -eq 0 ]]; then
    ok "═══ ALL RN ANDROID SAMPLES PASSED ═══"
else
    err "═══ $FAIL RN ANDROID SAMPLE(S) FAILED ═══"
    exit 1
fi
