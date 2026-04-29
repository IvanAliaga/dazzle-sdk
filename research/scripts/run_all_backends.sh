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
# run_all_backends.sh — Run the Sequential Monitoring Agent experiment
# against every configured storage backend, N times each, on a connected
# Android device. Collects all JSON results into
# research/benchmarks/results/<device>/<backend>/.
#
# Usage:
#   scripts/run_all_backends.sh                          # defaults: 5 runs × all backends
#   scripts/run_all_backends.sh --count 3                # 3 runs per backend
#   scripts/run_all_backends.sh --backends valkey,sqlite,sqlite-optimized,sqlite-precompute  # only these
#   scripts/run_all_backends.sh --count 1 --backends sqlite-precompute  # quick smoke
#
# Flags:
#   --count     runs per backend (default: 5)
#   --backends  comma-separated list
#   --timeout   per-run timeout in seconds (default: 900 = 15 min)
#   --results   output directory (default: experiment/results)
#
# Prerequisites:
#   - adb in $PATH, device connected
#   - APK installed: (cd android && ./gradlew :experiment:installDebug)
#   - Gemma model in the app's files dir (see run_experiment.sh header)
#
# Each backend run:
#   1. adb am force-stop dev.dazzle.experiment
#   2. rm completion marker
#   3. adb am start --ez auto_run true --ei run_count 1 --es backend <name>
#   4. Poll for marker (15 s interval)
#   5. Pull new JSON(s) to research/benchmarks/results/<device>/<backend>/
#   6. Repeat for each run

set -euo pipefail

COUNT=""
BACKENDS=""
TIMEOUT=""
STORAGE_ONLY=false
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results"
PKG="dev.dazzle.experiment"
MARKER="/sdcard/Documents/experiment_android_complete.marker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)        COUNT="$2";    shift 2 ;;
        --backends)     BACKENDS="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2";  shift 2 ;;
        --results)      RESULTS_DIR="$2"; shift 2 ;;
        --storage-only) STORAGE_ONLY=true; shift ;;
        -h|--help)      sed -n '3,30p' "$0"; exit 0 ;;
        *)              echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Defaults differ between storage-only smoke (fast, no Gemma) and full runs.
if [[ -z "$COUNT" ]];    then $STORAGE_ONLY && COUNT=10    || COUNT=5; fi
if [[ -z "$TIMEOUT" ]];  then $STORAGE_ONLY && TIMEOUT=120 || TIMEOUT=900; fi
if [[ -z "$BACKENDS" ]]; then
    if $STORAGE_ONLY; then
        BACKENDS="dazzle,dazzle-pipeline,dazzle-precompute,dazzle-lua,dazzle-hfe,dazzle-hll,valkey,sqlite,sqlite-optimized,sqlite-precompute,objectbox,lmdb,inmemory"
    else
        BACKENDS="dazzle,valkey,sqlite,sqlite-optimized,sqlite-precompute,objectbox,lmdb,rocksdb,inmemory"
    fi
fi

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ── Device check ──────────────────────────────────────────────────────────
command -v adb >/dev/null || fail "adb not in PATH"
DEVICE="${ANDROID_SERIAL:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
[[ -z "$DEVICE" ]] && fail "no Android device connected"
log "device: $DEVICE"

DEVICE_MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')
DEVICE_MFR=$(adb -s "$DEVICE" shell getprop ro.product.manufacturer | tr -d '\r')
DEVICE_NAME="${DEVICE_MFR}_${DEVICE_MODEL}"
DEVICE_NAME=$(echo "$DEVICE_NAME" | sed 's/ /_/g; s/[^a-zA-Z0-9_-]//g')
DEVICE_RESULTS="$RESULTS_DIR/$DEVICE_NAME"
mkdir -p "$DEVICE_RESULTS"

# Verify APK is installed
adb -s "$DEVICE" shell pm list packages 2>/dev/null | grep -q "package:$PKG" \
    || fail "$PKG not installed. Run: (cd android && ./gradlew :experiment:installDebug)"

IFS=',' read -ra BACKEND_LIST <<< "$BACKENDS"
log "backends: ${BACKEND_LIST[*]}"
log "count per backend: $COUNT"
log "total runs: $(( ${#BACKEND_LIST[@]} * COUNT ))"
log "results dir: $DEVICE_RESULTS"

TOTAL_PULLED=0

for BACKEND in "${BACKEND_LIST[@]}"; do
    BACKEND_DIR="$DEVICE_RESULTS/$BACKEND"
    mkdir -p "$BACKEND_DIR"

    log ""
    log "════════════════════════════════════════"
    log "  Backend: $BACKEND  ($COUNT runs)"
    log "════════════════════════════════════════"

    # Storage-only JSONs are named `storageonly_<backend>_<ts>.json`; full
    # runs write `experiment_android_*.json`. Filter by the current
    # backend key so old files from previous backends don't get mis-pulled.
    if $STORAGE_ONLY; then
        SAFE_BACKEND=$(printf '%s' "$BACKEND" | tr -c 'a-zA-Z0-9_-' '_')
        GLOB="/sdcard/Documents/storageonly_${SAFE_BACKEND}_*.json"
    else
        GLOB="/sdcard/Documents/experiment_android_*.json"
    fi
    EXISTING=$(adb -s "$DEVICE" shell "ls $GLOB 2>/dev/null" | tr -d '\r' || true)

    for RUN_IDX in $(seq 1 "$COUNT"); do
        log "── $BACKEND run $RUN_IDX / $COUNT ──"

        # Clean slate
        adb -s "$DEVICE" shell "am force-stop $PKG" >/dev/null 2>&1 || true
        adb -s "$DEVICE" shell "rm -f $MARKER"       >/dev/null 2>&1 || true

        # Launch: storage-only vs full-Gemma paths pick different extras.
        if $STORAGE_ONLY; then
            adb -s "$DEVICE" shell am start -n "$PKG/.ExperimentActivity" \
                --ez test_storage_only true --es backend "$BACKEND" >/dev/null
        else
            adb -s "$DEVICE" shell am start -n "$PKG/.ExperimentActivity" \
                --ez auto_run true --ei run_count 1 --es backend "$BACKEND" >/dev/null
        fi

        # Poll for marker. Storage-only runs finish in 1-3s; full Gemma runs
        # take minutes — use a shorter interval for the former so the
        # loop doesn't sit idle for 13s after completion.
        DEADLINE=$(( $(date +%s) + TIMEOUT ))
        POLL_INTERVAL=15
        $STORAGE_ONLY && POLL_INTERVAL=2
        log "  waiting for marker (timeout ${TIMEOUT}s, poll ${POLL_INTERVAL}s)"
        while true; do
            if (( $(date +%s) > DEADLINE )); then
                warn "  $BACKEND run $RUN_IDX timed out after ${TIMEOUT}s — skipping"
                break
            fi
            # `|| true` so the script doesn't exit when the marker file
            # doesn't exist yet (pipefail + set -e would trigger).
            MARKER_BODY=$(adb -s "$DEVICE" shell "cat $MARKER 2>/dev/null" | tr -d '\r' || true)
            if [[ -n "$MARKER_BODY" ]]; then
                log "  marker: $MARKER_BODY"
                [[ "$MARKER_BODY" != *" ok "* ]] && warn "  non-ok status"
                break
            fi
            sleep "$POLL_INTERVAL"
        done
    done

    # Pull all new JSONs for this backend (same glob we snapshotted with)
    ALL_NOW=$(adb -s "$DEVICE" shell "ls $GLOB 2>/dev/null" | tr -d '\r' || true)
    PULLED=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if ! grep -Fxq "$path" <<<"$EXISTING"; then
            BASE=$(basename "$path")
            adb -s "$DEVICE" pull "$path" "$BACKEND_DIR/$BASE" >/dev/null
            PULLED=$((PULLED + 1))
        fi
    done <<<"$ALL_NOW"
    log "$BACKEND: pulled $PULLED JSON file(s) to $BACKEND_DIR"
    TOTAL_PULLED=$((TOTAL_PULLED + PULLED))

    # Update the existing snapshot for the next backend
    EXISTING="$ALL_NOW"
done

log ""
log "════════════════════════════════════════"
log "  ALL DONE — $TOTAL_PULLED total JSON files"
log "════════════════════════════════════════"
log "Results are in $DEVICE_RESULTS/<backend>/"
log "Run research/scripts/analyze_results.py $DEVICE_RESULTS to generate the paper tables."
