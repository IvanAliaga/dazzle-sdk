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
# run_storage_microbench_per_backend_ios.sh
#
# Isolated iOS storage-only microbenchmark per backend.
#
# Properties:
# - One backend per run (count=1)
# - Randomized backend order per round
# - Dedicated timestamped output root (no historical mixing)
#
# Usage:
#   research/scripts/run_storage_microbench_per_backend_ios.sh
#   research/scripts/run_storage_microbench_per_backend_ios.sh --rounds 20
#   research/scripts/run_storage_microbench_per_backend_ios.sh \
#     --backends dazzle-precompute,sqlite,sqlite-optimized,inmemory --cooldown 2
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE_RESULTS_DIR="$REPO_ROOT/research/benchmarks/results/microbench_ios"
ROUNDS=10
COOLDOWN_SEC=1
BACKENDS="dazzle-precompute,sqlite,sqlite-optimized,inmemory"
DEVICE=""
DATASET_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds)    ROUNDS="$2"; shift 2 ;;
        --backends)  BACKENDS="$2"; shift 2 ;;
        --cooldown)  COOLDOWN_SEC="$2"; shift 2 ;;
        --results)   BASE_RESULTS_DIR="$2"; shift 2 ;;
        --device)    DEVICE="$2"; shift 2 ;;
        --dataset)   DATASET_NAME="$2"; shift 2 ;;
        -h|--help)
            sed -n '20,44p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$BASE_RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT_DIR"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

to_lines() {
    local csv="$1"
    python3 - "$csv" <<'PY'
import sys
items=[x.strip() for x in sys.argv[1].split(",") if x.strip()]
print("\n".join(items))
PY
}

shuffle_csv() {
    local csv="$1"
    python3 - "$csv" <<'PY'
import random, sys
items=[x.strip() for x in sys.argv[1].split(",") if x.strip()]
random.shuffle(items)
print("\n".join(items))
PY
}

log "iOS microbench run id: $RUN_ID"
log "Rounds: $ROUNDS"
log "Backends: $BACKENDS"
log "Cooldown between runs: ${COOLDOWN_SEC}s"
log "Output root: $OUT_DIR"
[[ -n "$DEVICE" ]] && log "Device override: $DEVICE"
[[ -n "$DATASET_NAME" ]] && log "Dataset override: $DATASET_NAME"

for ROUND in $(seq 1 "$ROUNDS"); do
    log ""
    log "════════ Round $ROUND / $ROUNDS ════════"

    ORDER="$(shuffle_csv "$BACKENDS")"
    mapfile -t ORDER_ARR <<< "$ORDER"
    log "Order:"
    for BK in "${ORDER_ARR[@]}"; do
        [[ -z "$BK" ]] && continue
        log "  - $BK"
    done

    for BK in "${ORDER_ARR[@]}"; do
        [[ -z "$BK" ]] && continue
        log "Run backend=$BK (count=1)"

        CMD=( "$REPO_ROOT/research/scripts/run_ios_benchmark.sh"
              --storage-only
              --count 1
              --backends "$BK"
              --results "$OUT_DIR" )
        if [[ -n "$DATASET_NAME" ]]; then
            CMD+=( --dataset "$DATASET_NAME" )
        fi
        if [[ -n "$DEVICE" ]]; then
            CMD+=( --device "$DEVICE" )
        fi
        "${CMD[@]}"
        sleep "$COOLDOWN_SEC"
    done
done

log ""
log "iOS microbench complete."
log "Results directory: $OUT_DIR"
log "Analyze per device with:"
log "  python3 research/scripts/analyze_storage_microbench.py $OUT_DIR"
