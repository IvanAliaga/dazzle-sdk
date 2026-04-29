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
# run_ablation_sweep.sh — external driver for the ablation matrix.
#
# Iterates 4 variants externally (baseline / + workers / + snap-linear /
# + hash-index), each as a fresh am start invocation with am force-stop
# between them. This sidesteps the fact that embedded-Valkey's second
# valkey_main() invocation in the same process is not robust — an
# in-process variant switch reliably hangs.
#
# Each per-variant run executes the inner K × backend matrix inside the
# APK (AblationSweep.run with a single-element variants list), so we pay
# N variant APK cold-starts, not N*K*B.
#
# Usage:
#   scripts/run_ablation_sweep.sh
#   scripts/run_ablation_sweep.sh --ks 1,2,4,8,16 --backends dazzle-precompute \
#       --duration 20
#   scripts/run_ablation_sweep.sh --variants "baseline,+ hash-index"
#
# Flags:
#   --ks         comma K values (default: 1,2,4,8)
#   --backends   comma backend keys (default: dazzle-precompute,dazzle-incremental)
#   --variants   comma variant names (default: all 4 defaults)
#   --duration   seconds per cell (default: 15)
#   --read-pct   80/20 read/write mix knob (default: 80)
#   --workers    worker thread count override (default: 0 = SoC auto)

set -euo pipefail

KS="1,2,4,8"
BACKENDS="dazzle-precompute,dazzle-incremental"
VARIANTS_CSV="baseline,workers,snap-linear-serial,snap-linear,hash-index-serial,hash-index"
DURATION=15
READ_PCT=80
WORKERS=0

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results/ablation"
PKG="dev.dazzle.experiment.multiagent"
ACT="dev.dazzle.experiment.MultiAgentActivity"
MARKER="/sdcard/Documents/experiment_android_complete.marker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ks)        KS="$2";           shift 2 ;;
        --backends)  BACKENDS="$2";     shift 2 ;;
        --variants)  VARIANTS_CSV="$2"; shift 2 ;;
        --duration)  DURATION="$2";     shift 2 ;;
        --read-pct)  READ_PCT="$2";     shift 2 ;;
        --workers)   WORKERS="$2";      shift 2 ;;
        --results)   RESULTS_DIR="$2";  shift 2 ;;
        -h|--help)   sed -n '3,47p' "$0"; exit 0 ;;
        *)           echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$RESULTS_DIR"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

command -v adb >/dev/null || fail "adb not in PATH"
DEVICE="${ANDROID_SERIAL:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
[[ -z "$DEVICE" ]] && fail "no Android device connected"
log "device: $DEVICE"

adb -s "$DEVICE" shell pm list packages 2>/dev/null | grep -q "package:$PKG" \
    || fail "$PKG not installed. Run: (cd sdk/android && ./gradlew :experiment-multiagent:installDebug)"

IFS=',' read -ra KS_ARR       <<< "$KS"
IFS=',' read -ra BACKENDS_ARR <<< "$BACKENDS"
IFS=',' read -ra VARIANTS_ARR <<< "$VARIANTS_CSV"
CELLS_PER_VARIANT=$(( ${#KS_ARR[@]} * ${#BACKENDS_ARR[@]} ))
TOTAL_CELLS=$((${#VARIANTS_ARR[@]} * CELLS_PER_VARIANT))
PER_VARIANT_TIMEOUT=$(( DURATION * CELLS_PER_VARIANT + 60 ))

log "sweep: ${#VARIANTS_ARR[@]} variants × K=[$KS] × backends=[$BACKENDS]"
log "cells=$TOTAL_CELLS  duration=${DURATION}s/cell  per-variant timeout=${PER_VARIANT_TIMEOUT}s"

# Snapshot existing per-variant JSONs so we only pull the new ones.
EXISTING=$(adb -s "$DEVICE" shell "ls /sdcard/Documents/ablation_sweep_*.json 2>/dev/null" \
    | tr -d '\r' || true)

for VARIANT in "${VARIANTS_ARR[@]}"; do
    log ""
    log "════════════════════════════════════════"
    log "  variant: $VARIANT"
    log "════════════════════════════════════════"

    adb -s "$DEVICE" shell "am force-stop $PKG" >/dev/null 2>&1 || true
    adb -s "$DEVICE" shell "rm -f $MARKER"      >/dev/null 2>&1 || true
    sleep 1   # let force-stop settle before relaunch

    adb -s "$DEVICE" shell am start -n "$PKG/$ACT" \
        --es mode sweep \
        --es sweep_ks        "$KS" \
        --es sweep_backends  "$BACKENDS" \
        --es sweep_variants  "$VARIANT" \
        --ei sweep_duration_sec "$DURATION" \
        --ei sweep_read_pct     "$READ_PCT" \
        --ei sweep_worker_threads "$WORKERS" \
        >/dev/null

    DEADLINE=$(( $(date +%s) + PER_VARIANT_TIMEOUT ))
    log "waiting for variant marker (timeout ${PER_VARIANT_TIMEOUT}s) …"
    while true; do
        if (( $(date +%s) > DEADLINE )); then
            warn "variant '$VARIANT' timed out — skipping rest of sweep"
            break 2
        fi
        MARKER_BODY=$(adb -s "$DEVICE" shell "cat $MARKER 2>/dev/null" | tr -d '\r' || true)
        if [[ -n "$MARKER_BODY" ]]; then
            log "  marker: $MARKER_BODY"
            [[ "$MARKER_BODY" != *" ok "* ]] && warn "  non-ok status for '$VARIANT'"
            break
        fi
        sleep 10
    done
done

# Pull every new sweep JSON that appeared during the loop.
ALL_NOW=$(adb -s "$DEVICE" shell "ls /sdcard/Documents/ablation_sweep_*.json 2>/dev/null" \
    | tr -d '\r' || true)
PULLED=0
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if ! grep -Fxq "$path" <<<"$EXISTING"; then
        BASE=$(basename "$path")
        adb -s "$DEVICE" pull "$path" "$RESULTS_DIR/$BASE" >/dev/null
        log "pulled: $RESULTS_DIR/$BASE"
        PULLED=$((PULLED + 1))
    fi
done <<<"$ALL_NOW"

(( PULLED == 0 )) && fail "no new sweep JSON pulled — check marker / device logs"
log ""
log "DONE — $PULLED file(s) in $RESULTS_DIR/"
log "Run: python3 research/scripts/plot_ablation_sweep.py $RESULTS_DIR/*.json"
