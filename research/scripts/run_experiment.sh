#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# run_experiment.sh — automate N sequential runs of the Valkey × Gemma
# Sequential Monitoring Agent experiment on Android and/or iOS.
#
# Prerequisites (one-time):
#   Android
#     - adb in $PATH, device connected with USB debugging authorised.
#     - App installed on the device:
#         (cd android && ./gradlew :experiment:installDebug)
#     - Gemma model already present in the app's files dir:
#         adb push ~/Downloads/gemma-4-E2B-it.litertlm /sdcard/Android/data/dev.dazzle.experiment/files/
#         adb shell "cat /sdcard/Android/data/dev.dazzle.experiment/files/gemma-4-E2B-it.litertlm | \
#             run-as dev.dazzle.experiment dd of=/data/data/dev.dazzle.experiment/files/gemma-4-E2B-it.litertlm bs=1048576"
#   iOS
#     - Xcode + personal developer account signed in.
#     - App installed ONCE via Xcode (⌘R on the iPhone target) so provisioning is set up.
#     - Gemma model copied to the app's Documents via the iOS Files app.
#     - xcrun devicectl available (Xcode 15+).
#
# Usage:
#   scripts/run_experiment.sh --platform android --count 5
#   scripts/run_experiment.sh --platform ios --count 3 --ios-udid 00008101-00115DD93E44001E
#   scripts/run_experiment.sh --platform both --count 5
#
# Flags:
#   --platform  android | ios | both   (default: both)
#   --count     number of back-to-back runs per platform (default: 3)
#   --ios-udid  iPhone UDID, required for --platform ios|both
#                (get it from: xcrun xctrace list devices)
#   --timeout   per-platform overall timeout in seconds (default: 4800 = 80 min)
#   --results   local results directory (default: experiment/results)
#
# What it does:
#   Android: sends an Intent with auto_run=true + run_count=N. The activity
#            runs N times and drops experiment_android_complete.marker in
#            /sdcard/Documents when idle. We poll for the marker, then
#            adb-pull every experiment_android_*.json produced during the
#            window and move them into experiment/results/android/.
#
#   iOS:     launches the app via `xcrun devicectl device process launch` with
#            RUN_COUNT in the environment. The app drops
#            experiment_ios_complete.marker in Documents when done. We poll
#            for it via `devicectl device info apps` / file listing, then
#            pull the JSONs with `devicectl device copy from`.

set -euo pipefail

PLATFORM="both"
COUNT=3
IOS_UDID=""
TIMEOUT=4800
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results"
ANDROID_PKG="dev.dazzle.experiment"
IOS_BUNDLE="io.dazzle.experiment"
ANDROID_MARKER="/sdcard/Documents/experiment_android_complete.marker"
IOS_MARKER="experiment_ios_complete.marker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)  PLATFORM="$2";  shift 2 ;;
        --count)     COUNT="$2";     shift 2 ;;
        --ios-udid)  IOS_UDID="$2";  shift 2 ;;
        --timeout)   TIMEOUT="$2";   shift 2 ;;
        --results)   RESULTS_DIR="$2"; shift 2 ;;
        -h|--help)   sed -n '3,40p' "$0"; exit 0 ;;
        *)           echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$RESULTS_DIR/android" "$RESULTS_DIR/ios"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ────────────────────────────────────────────────────────────────────────────
# Android
# ────────────────────────────────────────────────────────────────────────────

run_android() {
    command -v adb >/dev/null || fail "adb not in PATH"
    local devices
    devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    [[ -z "$devices" ]] && fail "no Android device connected (adb devices is empty)"
    local n_devices
    n_devices=$(echo "$devices" | wc -l | tr -d ' ')
    [[ "$n_devices" -gt 1 ]] && warn "multiple Android devices connected, using the first one"
    local device
    device=$(echo "$devices" | head -1)
    log "Android device: $device"

    # Verify the APK is installed
    if ! adb -s "$device" shell pm list packages 2>/dev/null | grep -q "package:$ANDROID_PKG"; then
        fail "$ANDROID_PKG not installed on $device. Run: (cd android && ./gradlew :experiment:installDebug)"
    fi

    # Snapshot existing JSONs so we only pull what's new.
    local existing
    existing=$(adb -s "$device" shell "ls /sdcard/Documents/experiment_android_*.json 2>/dev/null" | tr -d '\r' || true)
    log "pre-existing Android JSON files: $(echo "$existing" | grep -c . || echo 0)"

    # LiteRT-LM's native engine cannot be re-instantiated in the same process
    # (SIGSEGV on the 2nd ctor, observed on Moto G35). So each run MUST get a
    # fresh process: we loop N times, force-stopping + re-launching the
    # activity per iteration with run_count=1. The activity also kills its
    # own process at the end of auto-run as a belt-and-braces measure.
    local run_idx
    for run_idx in $(seq 1 "$COUNT"); do
        log "── Android run $run_idx / $COUNT ──"

        # Clean slate
        adb -s "$device" shell "am force-stop $ANDROID_PKG" >/dev/null 2>&1 || true
        adb -s "$device" shell "rm -f $ANDROID_MARKER"       >/dev/null 2>&1 || true

        # Kick off
        adb -s "$device" shell am start -n "$ANDROID_PKG/.ExperimentActivity" \
            --ez auto_run true --ei run_count 1 >/dev/null

        # Poll for the marker
        local deadline=$(( $(date +%s) + TIMEOUT ))
        log "waiting for completion marker (timeout ${TIMEOUT}s)"
        local marker=""
        while true; do
            if (( $(date +%s) > deadline )); then
                fail "Android run $run_idx timed out after ${TIMEOUT}s"
            fi
            marker=$(adb -s "$device" shell "cat $ANDROID_MARKER 2>/dev/null" | tr -d '\r')
            if [[ -n "$marker" ]]; then
                log "run $run_idx marker: $marker"
                if [[ "$marker" != *" ok "* ]]; then
                    warn "run $run_idx reported non-ok status — keeping going"
                fi
                break
            fi
            sleep 15
        done
    done

    # Pull every experiment_android_*.json that didn't exist before we started
    log "pulling Android results"
    local all_now
    all_now=$(adb -s "$device" shell "ls /sdcard/Documents/experiment_android_*.json 2>/dev/null" | tr -d '\r' || true)
    local pulled=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if ! grep -Fxq "$path" <<<"$existing"; then
            local base
            base=$(basename "$path")
            adb -s "$device" pull "$path" "$RESULTS_DIR/android/$base" >/dev/null
            pulled=$((pulled + 1))
        fi
    done <<<"$all_now"
    log "Android complete — $pulled new JSON file(s) pulled to $RESULTS_DIR/android"
}

# ────────────────────────────────────────────────────────────────────────────
# iOS
# ────────────────────────────────────────────────────────────────────────────

run_ios() {
    command -v xcrun >/dev/null || fail "xcrun not in PATH (needs Xcode)"
    command -v python3 >/dev/null || fail "python3 not in PATH (needed to parse devicectl JSON)"

    # `xcrun devicectl` uses its own per-host CoreDevice identifier which is
    # NOT the classic iOS UDID shown by `xctrace list devices`. If the user
    # passes the classic UDID we resolve it via devicectl's JSON output; if
    # they pass no UDID at all we pick the only connected iPhone.
    local devs_json
    devs_json=$(mktemp)
    trap 'rm -f "$devs_json"' RETURN
    xcrun devicectl list devices --json-output "$devs_json" >/dev/null 2>&1 \
        || fail "xcrun devicectl list devices failed"

    local resolved
    resolved=$(python3 - "$devs_json" "${IOS_UDID:-}" <<'PY'
import json, sys
path, wanted = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
devices = data.get("result", {}).get("devices", [])
connected = []
for d in devices:
    if d.get("connectionProperties", {}).get("tunnelState") != "connected":
        continue
    props = d.get("hardwareProperties", {})
    if props.get("deviceType") != "iPhone":
        continue
    connected.append(d)
def match(d):
    if not wanted:
        return True
    ids = {
        d.get("identifier", ""),
        d.get("hardwareProperties", {}).get("udid", ""),
        d.get("hardwareProperties", {}).get("ecid", ""),
        d.get("hardwareProperties", {}).get("serialNumber", ""),
    }
    return wanted in ids
hits = [d for d in connected if match(d)]
if not hits:
    sys.exit(1)
if len(hits) > 1 and not wanted:
    # Multiple connected iPhones and the user did not disambiguate.
    print("__ambiguous__")
    for d in hits:
        print(d["identifier"], d.get("hardwareProperties", {}).get("productType", "?"))
    sys.exit(2)
print(hits[0]["identifier"])
PY
    )
    local rc=$?
    if [[ $rc -eq 1 ]]; then
        if [[ -n "$IOS_UDID" ]]; then
            fail "no connected iPhone matches --ios-udid=$IOS_UDID (run: xcrun devicectl list devices)"
        else
            fail "no connected iPhone found (run: xcrun devicectl list devices)"
        fi
    fi
    if [[ $rc -eq 2 ]]; then
        warn "multiple connected iPhones, pass --ios-udid explicitly:"
        warn "$resolved"
        fail "ambiguous iOS target"
    fi
    IOS_UDID="$resolved"
    log "iOS CoreDevice identifier: $IOS_UDID"

    local pull_dir pre_snapshot
    pull_dir=$(mktemp -d)
    pre_snapshot=$(mktemp)
    trap 'rm -rf "$pull_dir" "$pre_snapshot"' RETURN

    # Pre-snapshot: list the JSONs we already have in the container so we
    # only copy NEW ones back after the runs finish.
    log "pre-snapshot of iOS Documents container"
    local pre_pull
    pre_pull=$(mktemp -d)
    xcrun devicectl device copy from \
        --device "$IOS_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$IOS_BUNDLE" \
        --user mobile \
        --source "Documents" \
        --destination "$pre_pull" \
        --quiet 2>/dev/null || warn "pre-snapshot pull failed (first run?)"
    (cd "$pre_pull" 2>/dev/null && find . -name 'experiment_ios_*.json' -type f -print 2>/dev/null \
        | sed 's|^\./||') | sort > "$pre_snapshot"
    log "pre-existing iOS JSON files: $(wc -l < "$pre_snapshot" | tr -d ' ')"
    rm -rf "$pre_pull"

    # LiteRT-LM's native engine segfaults on re-init inside the same process
    # (see ExperimentPipelineIoTValkey8.kt / ExperimentView.swift comments) — so each
    # run has to come from a fresh launch. The app is built to call exit(0)
    # after its one auto run when RUN_COUNT is set in the environment, and
    # we loop here externally.
    local run_idx marker_probe
    marker_probe=$(mktemp -d)
    for run_idx in $(seq 1 "$COUNT"); do
        log "── iOS run $run_idx / $COUNT ──"

        # Kill any leftover instance and wipe the old marker
        xcrun devicectl device process terminate \
            --device "$IOS_UDID" \
            --bundle-identifier "$IOS_BUNDLE" >/dev/null 2>&1 || true
        # (devicectl has no direct "delete file" op; overwriting the marker on
        # next run is sufficient, we probe for it by copy-from which only
        # succeeds once the new marker lands.)

        log "launching $IOS_BUNDLE with RUN_COUNT=1"
        xcrun devicectl device process launch \
            --device "$IOS_UDID" \
            --environment-variables "{\"RUN_COUNT\":\"1\"}" \
            --terminate-existing \
            "$IOS_BUNDLE" >/dev/null

        # Poll for the marker file. `device copy from` exits non-zero when
        # the source doesn't exist — we use that as a cheap existence probe
        # instead of parsing the non-stable text output of `device info files`.
        local deadline=$(( $(date +%s) + TIMEOUT ))
        log "polling for $IOS_MARKER (timeout ${TIMEOUT}s)"
        # Remove any marker we might have pulled in a previous iteration so
        # we don't mistake it for a new one.
        rm -f "$marker_probe/$IOS_MARKER"
        while true; do
            if (( $(date +%s) > deadline )); then
                rm -rf "$marker_probe"
                fail "iOS run $run_idx timed out after ${TIMEOUT}s"
            fi
            if xcrun devicectl device copy from \
                --device "$IOS_UDID" \
                --domain-type appDataContainer \
                --domain-identifier "$IOS_BUNDLE" \
                --user mobile \
                --source "Documents/$IOS_MARKER" \
                --destination "$marker_probe/" \
                --quiet 2>/dev/null; then
                local marker_body
                marker_body=$(cat "$marker_probe/$IOS_MARKER" 2>/dev/null || echo "")
                log "run $run_idx marker: $marker_body"
                [[ "$marker_body" != *" ok "* ]] && warn "run $run_idx reported non-ok — keeping going"
                break
            fi
            sleep 15
        done
    done
    rm -rf "$marker_probe"

    # Pull the container once at the end and keep only new JSONs
    log "pulling iOS results"
    xcrun devicectl device copy from \
        --device "$IOS_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$IOS_BUNDLE" \
        --user mobile \
        --source "Documents" \
        --destination "$pull_dir" \
        --quiet 2>/dev/null \
        || fail "failed to pull Documents from iOS device"

    local post_snapshot
    post_snapshot=$(mktemp)
    (cd "$pull_dir" && find . -name 'experiment_ios_*.json' -type f -print \
        | sed 's|^\./||') | sort > "$post_snapshot"
    local pulled=0
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if ! grep -Fxq "$rel" "$pre_snapshot"; then
            local src="$pull_dir/$rel"
            local base
            base=$(basename "$rel")
            if [[ -f "$src" ]]; then
                cp "$src" "$RESULTS_DIR/ios/$base"
                pulled=$((pulled + 1))
            fi
        fi
    done < "$post_snapshot"
    rm -f "$post_snapshot"
    log "iOS complete — $pulled new JSON file(s) pulled to $RESULTS_DIR/ios"
}

# ────────────────────────────────────────────────────────────────────────────
# Dispatch
# ────────────────────────────────────────────────────────────────────────────

log "repo root: $REPO_ROOT"
log "platform=$PLATFORM  count=$COUNT  timeout=${TIMEOUT}s  results=$RESULTS_DIR"

case "$PLATFORM" in
    android) run_android ;;
    ios)     run_ios ;;
    both)    run_android; run_ios ;;
    *)       fail "invalid --platform: $PLATFORM" ;;
esac

log "all done"
