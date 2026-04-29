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
# run_full_benchmark.sh — Comprehensive benchmark automation for the paper.
#
# Runs storage-only tests, full Gemma experiments, and scale benchmarks
# across all backends on a specified device. Organises results by
# device/backend/ for the analysis script.
#
# Usage:
#   # Storage-only: 11 backends × 10 runs (~2 min total)
#   scripts/run_full_benchmark.sh --storage-only --count 10
#
#   # Full Gemma experiment: 11 backends × 5 runs (~6.5 hours)
#   scripts/run_full_benchmark.sh --count 5
#
#   # Scale benchmark: retrieval vs N (200..100000)
#   scripts/run_full_benchmark.sh --scale --backends dazzle-precompute,sqlite,inmemory
#
#   # Specify device explicitly
#   scripts/run_full_benchmark.sh --device ZE223FPXBS --storage-only --count 10
#
# Flags:
#   --device      ADB device serial (default: first connected)
#   --count       Runs per backend (default: 5 for full, 10 for storage-only)
#   --backends    Comma-separated list (default: all configured backends)
#   --storage-only  Run without Gemma (fast retrieval/ingest test)
#   --scale       Run scale benchmark (retrieval vs N)
#   --scale-counts  Comma-separated N values (default: 200,1000,5000,20000)
#   --timeout     Per-run timeout in seconds (default: 900)
#   --results     Output directory (default: experiment/results)
#
set -euo pipefail

ALL_BACKENDS="dazzle,dazzle-pipeline,dazzle-precompute,dazzle-lua,dazzle-hfe,dazzle-hll,valkey,sqlite,sqlite-optimized,sqlite-precompute,rocksdb,objectbox,lmdb,inmemory"
COUNT=""  # will default based on mode
BACKENDS="$ALL_BACKENDS"
TIMEOUT=900
STORAGE_ONLY=false
SCALE=false
SCALE_COUNTS="200,1000,5000,20000"
DEVICE=""
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results"
PKG="dev.dazzle.experiment"
MARKER="/sdcard/Documents/experiment_android_complete.marker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)       DEVICE="$2";       shift 2 ;;
        --count)        COUNT="$2";        shift 2 ;;
        --backends)     BACKENDS="$2";     shift 2 ;;
        --timeout)      TIMEOUT="$2";      shift 2 ;;
        --results)      RESULTS_DIR="$2";  shift 2 ;;
        --storage-only) STORAGE_ONLY=true; shift ;;
        --scale)        SCALE=true;        shift ;;
        --scale-counts) SCALE_COUNTS="$2"; shift 2 ;;
        -h|--help)      sed -n '3,28p' "$0"; exit 0 ;;
        *)              echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Default count based on mode
if [[ -z "$COUNT" ]]; then
    if $STORAGE_ONLY; then COUNT=10; else COUNT=5; fi
fi

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ── Device check ──────────────────────────────────────────────────────────
command -v adb >/dev/null || fail "adb not in PATH"

if [[ -z "$DEVICE" ]]; then
    DEVICE=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
fi
[[ -z "$DEVICE" ]] && fail "no Android device connected"
log "device serial: $DEVICE"

# Collect device metadata
DEVICE_MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')
DEVICE_MFR=$(adb -s "$DEVICE" shell getprop ro.product.manufacturer | tr -d '\r')
DEVICE_BOARD=$(adb -s "$DEVICE" shell getprop ro.product.board | tr -d '\r')
DEVICE_SDK=$(adb -s "$DEVICE" shell getprop ro.build.version.sdk | tr -d '\r')
DEVICE_ABI=$(adb -s "$DEVICE" shell getprop ro.product.cpu.abi | tr -d '\r')
DEVICE_RAM_KB=$(adb -s "$DEVICE" shell "cat /proc/meminfo | head -1" | awk '{print $2}' | tr -d '\r')

# Human-friendly device name for directory structure
DEVICE_NAME="${DEVICE_MFR}_${DEVICE_MODEL}"
DEVICE_NAME=$(echo "$DEVICE_NAME" | sed 's/ /_/g; s/[^a-zA-Z0-9_-]//g')

log "device: $DEVICE_MFR $DEVICE_MODEL ($DEVICE_BOARD)"
log "  RAM: ${DEVICE_RAM_KB} KB, SDK: $DEVICE_SDK, ABI: $DEVICE_ABI"

# Verify APK is installed
adb -s "$DEVICE" shell pm list packages 2>/dev/null | grep -q "package:$PKG" \
    || fail "$PKG not installed. Run: (cd android && ./gradlew :experiment:installDebug)"

IFS=',' read -ra BACKEND_LIST <<< "$BACKENDS"

# Determine mode
if $SCALE; then
    MODE="scale"
elif $STORAGE_ONLY; then
    MODE="storage_only"
else
    MODE="full"
fi

log "mode: $MODE"
log "backends: ${BACKEND_LIST[*]}"
log "count per backend: $COUNT"
log "total runs: $(( ${#BACKEND_LIST[@]} * COUNT ))"

# ── Create results directory structure ────────────────────────────────────
DEVICE_RESULTS="$RESULTS_DIR/$DEVICE_NAME"
mkdir -p "$DEVICE_RESULTS"

# Write device metadata file
cat > "$DEVICE_RESULTS/device_info.json" <<DEVJSON
{
  "serial": "$DEVICE",
  "model": "$DEVICE_MODEL",
  "manufacturer": "$DEVICE_MFR",
  "board": "$DEVICE_BOARD",
  "sdk_int": $DEVICE_SDK,
  "abi": "$DEVICE_ABI",
  "ram_total_kb": $DEVICE_RAM_KB
}
DEVJSON
log "device info written to $DEVICE_RESULTS/device_info.json"

TOTAL_PULLED=0
START_TIME=$(date +%s)

# ── Main loop ─────────────────────────────────────────────────────────────

for BACKEND in "${BACKEND_LIST[@]}"; do
    BACKEND_DIR="$DEVICE_RESULTS/$BACKEND"
    mkdir -p "$BACKEND_DIR"

    log ""
    log "════════════════════════════════════════"
    log "  Backend: $BACKEND  ($COUNT runs, mode=$MODE)"
    log "════════════════════════════════════════"

    for RUN_IDX in $(seq 1 "$COUNT"); do
        log "── $BACKEND run $RUN_IDX / $COUNT ──"

        # Snapshot existing result files (storage-only produces storageonly_*.json)
        if $STORAGE_ONLY; then
            PATTERN="/sdcard/Documents/storageonly_*.json"
        elif $SCALE; then
            PATTERN="/sdcard/Documents/scale_*.json"
        else
            PATTERN="/sdcard/Documents/experiment_android_*.json"
        fi
        EXISTING=$(adb -s "$DEVICE" shell "ls $PATTERN 2>/dev/null" | tr -d '\r' || true)

        # Clean slate
        adb -s "$DEVICE" shell "am force-stop $PKG" >/dev/null 2>&1 || true
        adb -s "$DEVICE" shell "rm -f $MARKER"       >/dev/null 2>&1 || true

        # Launch
        if $SCALE; then
            adb -s "$DEVICE" shell am start -n "$PKG/.ExperimentActivity" \
                --ez scale_benchmark true \
                --es backend "$BACKEND" \
                --es scale_counts "$SCALE_COUNTS" >/dev/null
        elif $STORAGE_ONLY; then
            adb -s "$DEVICE" shell am start -n "$PKG/.ExperimentActivity" \
                --ez test_storage_only true \
                --es backend "$BACKEND" >/dev/null
        else
            adb -s "$DEVICE" shell am start -n "$PKG/.ExperimentActivity" \
                --ez auto_run true --ei run_count 1 \
                --es backend "$BACKEND" >/dev/null
        fi

        # Poll for completion marker
        DEADLINE=$(( $(date +%s) + TIMEOUT ))
        POLL_INTERVAL=5
        if ! $STORAGE_ONLY; then POLL_INTERVAL=15; fi
        log "  waiting for marker (timeout ${TIMEOUT}s, poll ${POLL_INTERVAL}s)"

        while true; do
            if (( $(date +%s) > DEADLINE )); then
                warn "  $BACKEND run $RUN_IDX timed out after ${TIMEOUT}s — skipping"
                break
            fi
            MARKER_BODY=$(adb -s "$DEVICE" shell "cat $MARKER 2>/dev/null || true" | tr -d '\r')
            if [[ -n "$MARKER_BODY" ]]; then
                log "  marker: $MARKER_BODY"
                if [[ "$MARKER_BODY" != *" ok "* ]]; then warn "  non-ok status"; fi
                break
            fi
            sleep "$POLL_INTERVAL"
        done

        # Pull new result files
        ALL_NOW=$(adb -s "$DEVICE" shell "ls $PATTERN 2>/dev/null" | tr -d '\r' || true)
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            if ! grep -Fxq "$path" <<<"$EXISTING" 2>/dev/null; then
                BASE=$(basename "$path")
                adb -s "$DEVICE" pull "$path" "$BACKEND_DIR/$BASE" >/dev/null 2>&1
                TOTAL_PULLED=$((TOTAL_PULLED + 1))
                log "  pulled: $BASE"
            fi
        done <<<"$ALL_NOW"
    done
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

log ""
log "════════════════════════════════════════"
log "  ALL DONE — $TOTAL_PULLED JSON files in ${ELAPSED}s"
log "════════════════════════════════════════"
log "Results: $DEVICE_RESULTS/<backend>/"
log "Run: python3 research/scripts/analyze_results.py $DEVICE_RESULTS"
