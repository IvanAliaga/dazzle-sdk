#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end headless test of the React Native samples on iPhone.
# Mirror of test_flutter_ios.sh. Builds a release IPA (iOS blocks JIT
# so debug-from-Metro won't launch standalone), installs via
# devicectl, launches with DAZZLE_SAMPLE_TEST=1 env, pulls the JSON
# report from Documents.

set -uo pipefail

# Ruby-2.7 cocoapods-1.16 chokes on non-UTF-8 locale.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$HERE/_scripts/_test_results"
mkdir -p "$RESULTS"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

CORE_DEVICE="${CORE_DEVICE:-7C7BF335-CC32-5A31-8686-00195459CB50}"
HW_UUID="${HW_UUID:-00008101-00115DD93E44001E}"
log "iOS device: CORE=$CORE_DEVICE  HW=$HW_UUID"

# Free-profile 3-app cap — clear any previously installed dev-signed
# Dazzle apps so this test's install has a slot.
for stale in \
    io.dazzle.experiment.backends \
    io.dazzle.experiment \
    io.dazzle.experiment.storage \
    io.dazzle.experiment.multiagent \
    io.dazzle.samples.chatmemory io.dazzle.samples.chatiot io.dazzle.samples.chatkb \
    dev.dazzle.samples.dazzleChatMemoryFlutter \
    dev.dazzle.samples.dazzleChatIotFlutter \
    dev.dazzle.samples.dazzleChatKbFlutter \
    dev.dazzle.samples.dazzlechatmemoryrn \
    dev.dazzle.samples.dazzlechatiotrn \
    dev.dazzle.samples.dazzlechatkbrn; do
    # (no-op)
    xcrun devicectl device uninstall app --device "$CORE_DEVICE" \
        "$stale" 2>/dev/null >/dev/null || true
done

FAIL=0

test_one() {
    local name="$1"
    local app_dir="$HERE/${name}-rn"
    # Scheme + workspace follow the `chat_<kind>_rn` naming that
    # `react-native init chat_<kind>_rn` produced. Project folder is
    # kebab-case (`chat-<kind>-rn`) but the Xcode bits are
    # snake-case.
    local scheme_name="${name//-/_}_rn"
    local xcw="$app_dir/ios/${scheme_name}.xcworkspace"

    # Read the bundle ID straight from the pbxproj so a temporary swap
    # (e.g. reusing an already-provisioned App ID to dodge the Apple
    # free-dev 10/7-day cap) is picked up automatically.
    local bundle_id
    bundle_id=$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' \
        "$app_dir/ios/${scheme_name}.xcodeproj/project.pbxproj" 2>/dev/null \
        | sed -E 's|.*= ([^;]+);.*|\1|' | tr -d '"')
    [[ -z "$bundle_id" ]] && \
        bundle_id="dev.dazzle.samples.dazzle${name//-/}rn"

    log "══ ${name}-rn ══  ($bundle_id)"

    log "  npm install"
    (cd "$app_dir" && npm install --no-audit --no-fund 2>&1 | tail -2) \
        || { err "  npm install failed"; FAIL=1; return; }

    log "  pod install"
    (cd "$app_dir/ios" && rm -rf Pods Podfile.lock && \
        pod install 2>&1 | tail -5) \
        || { err "  pod install failed"; FAIL=1; return; }

    log "  pre-bundling JS (release mode, standalone APK/app)"
    (cd "$app_dir" && npx react-native bundle \
        --platform ios --dev false \
        --entry-file index.js \
        --bundle-output ios/main.jsbundle \
        --assets-dest ios/ 2>&1 | tail -3) \
        || { err "  bundle failed"; FAIL=1; return; }

    log "  xcodebuild Release"
    (cd "$app_dir/ios" && xcodebuild \
        -workspace "$(basename "$xcw")" \
        -scheme "$scheme_name" \
        -configuration Release \
        -destination "id=$HW_UUID" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM=H886H7AS9G \
        CODE_SIGN_STYLE=Automatic \
        build 2>&1 | tail -5) >/dev/null \
        || { err "  xcodebuild Release failed"; FAIL=1; return; }

    local app_path
    app_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*$scheme_name*/Build/Products/Release-iphoneos/$scheme_name.app" \
        -type d 2>/dev/null | head -1)
    if [[ -z "$app_path" ]]; then
        err "  $scheme_name.app not found under DerivedData"
        FAIL=1; return
    fi

    log "  installing $app_path"
    xcrun devicectl device install app --device "$CORE_DEVICE" "$app_path" \
        >/dev/null 2>&1 \
        || { err "  devicectl install failed"; FAIL=1; return; }

    log "  launching"
    xcrun devicectl device process launch --device "$CORE_DEVICE" \
        --terminate-existing \
        --environment-variables '{"DAZZLE_SAMPLE_TEST":"1"}' \
        "$bundle_id" >/dev/null 2>&1 \
        || { err "  launch failed"; FAIL=1; return; }

    # Test mode renders the chat live + holds a ~5s post-run banner.
    local deadline=$(($(date +%s) + 150))
    local pulled=""
    while (( $(date +%s) < deadline )); do
        local tmp
        tmp=$(mktemp -d)
        if xcrun devicectl device copy from --device "$CORE_DEVICE" \
              --domain-type appDataContainer \
              --domain-identifier "$bundle_id" \
              --source Documents --destination "$tmp" >/dev/null 2>&1; then
            local root="$tmp"
            [[ -d "$tmp/Documents" ]] && root="$tmp/Documents"
            if [[ -f "$root/sample_test_${name}.json" ]]; then
                pulled="$root/sample_test_${name}.json"
                cp "$pulled" "$RESULTS/${name}_rn_ios.json"
                rm -rf "$tmp"; break
            fi
        fi
        rm -rf "$tmp"; sleep 3
    done

    if [[ -z "$pulled" ]]; then
        err "  timed out waiting for sample_test_${name}.json"
        FAIL=1; return
    fi

    local status
    status=$(python3 -c "import json; print(json.load(open('$RESULTS/${name}_rn_ios.json'))['status'])" 2>/dev/null)
    if [[ "$status" != "pass" ]]; then
        err "  status=$status"
        cat "$RESULTS/${name}_rn_ios.json" >&2
        FAIL=1; return
    fi

    if ! python3 "$HERE/_scripts/validate_sample_report.py" \
            "$name" "$RESULTS/${name}_rn_ios.json"; then
        err "  behavioural validation failed"
        FAIL=1; return
    fi

    ok "  PASS — $(python3 -c "
import json
d = json.load(open('$RESULTS/${name}_rn_ios.json'))
print(f\"{d['turn_count']} turns, {d['user_turns']}u/{d['assistant_turns']}a/{d['tool_turns']}t, {d['llm_call_count']} LLM calls, {d['elapsed_ms']}ms\")
")"

    xcrun devicectl device uninstall app --device "$CORE_DEVICE" \
        "$bundle_id" 2>/dev/null >/dev/null || true
}

# Free Apple Dev accounts cap at 10 App IDs / 7 days. If you're
# hitting that limit, export RN_IOS_SAMPLES="chat-memory" to run
# only a subset. A paid developer seat removes the cap.
if [[ -z "${RN_IOS_SAMPLES:-}" ]]; then
    test_one "chat-memory"
    test_one "chat-iot"
    test_one "chat-kb"
else
    for s in $RN_IOS_SAMPLES; do test_one "$s"; done
fi

echo
if [[ $FAIL -eq 0 ]]; then
    ok "═══ ALL RN iOS SAMPLES PASSED ═══"
else
    err "═══ $FAIL RN iOS SAMPLE(S) FAILED ═══"
    exit 1
fi
