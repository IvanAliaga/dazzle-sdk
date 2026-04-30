#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# SPDX-License-Identifier: Apache-2.0

#
# run_vector_sqlite_family_sweep.sh
#
# Runs the SQLite-family vector benchmark with N sweep:
#   backend = vector-bench-sqlite-family-sweep
#
# Output JSON pattern:
#   /sdcard/Documents/vecbench_sqlite_family_sweep_<MODEL>_<ts>.json
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="dev.dazzle.experiment"
MARKER="/sdcard/Documents/experiment_android_complete.marker"
ROUNDS=3
TIMEOUT=1200
COOLDOWN_SEC=3
BASE_RESULTS_DIR="$REPO_ROOT/research/benchmarks/results/vector_sqlite_family_sweep"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds)    ROUNDS="$2"; shift 2 ;;
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        --cooldown)  COOLDOWN_SEC="$2"; shift 2 ;;
        --results)   BASE_RESULTS_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '12,24p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

command -v adb >/dev/null || fail "adb not in PATH"
DEVICE="${ANDROID_SERIAL:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
[[ -z "$DEVICE" ]] && fail "no Android device connected"

DEVICE_MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')
DEVICE_MFR=$(adb -s "$DEVICE" shell getprop ro.product.manufacturer | tr -d '\r')
DEVICE_NAME="${DEVICE_MFR}_${DEVICE_MODEL}"
DEVICE_NAME=$(echo "$DEVICE_NAME" | sed 's/ /_/g; s/[^a-zA-Z0-9_-]//g')

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$BASE_RESULTS_DIR/$RUN_ID/$DEVICE_NAME"
mkdir -p "$OUT_DIR"

log "device: $DEVICE ($DEVICE_NAME)"
log "rounds: $ROUNDS"
log "timeout per run: ${TIMEOUT}s"
log "output dir: $OUT_DIR"

GLOB="/sdcard/Documents/vecbench_sqlite_family_sweep_*.json"
EXISTING=$(adb -s "$DEVICE" shell "ls $GLOB 2>/dev/null" | tr -d '\r' || true)

for RUN_IDX in $(seq 1 "$ROUNDS"); do
    log "── run $RUN_IDX / $ROUNDS ──"
    adb -s "$DEVICE" shell "am force-stop $PKG" >/dev/null 2>&1 || true
    adb -s "$DEVICE" shell "rm -f $MARKER" >/dev/null 2>&1 || true

    adb -s "$DEVICE" shell am start -n "$PKG/.ExperimentActivity" \
        --ez test_storage_only true \
        --es backend vector-bench-sqlite-family-sweep >/dev/null

    DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while true; do
        if (( $(date +%s) > DEADLINE )); then
            warn "run $RUN_IDX timed out after ${TIMEOUT}s"
            break
        fi
        MARKER_BODY=$(adb -s "$DEVICE" shell "cat $MARKER 2>/dev/null" | tr -d '\r' || true)
        if [[ -n "$MARKER_BODY" ]]; then
            log "marker: $MARKER_BODY"
            [[ "$MARKER_BODY" != *" ok "* ]] && warn "non-ok status"
            break
        fi
        sleep 2
    done
    sleep "$COOLDOWN_SEC"
done

ALL_NOW=$(adb -s "$DEVICE" shell "ls $GLOB 2>/dev/null" | tr -d '\r' || true)
PULLED=0
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if ! grep -Fxq "$path" <<<"$EXISTING"; then
        base=$(basename "$path")
        adb -s "$DEVICE" pull "$path" "$OUT_DIR/$base" >/dev/null
        PULLED=$((PULLED + 1))
    fi
done <<<"$ALL_NOW"

log "pulled $PULLED json file(s) to $OUT_DIR"
log "analyze with:"
log "  python3 research/scripts/analyze_vector_sqlite_family_sweep.py $OUT_DIR"
