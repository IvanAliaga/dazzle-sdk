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
# run_reviewer_mitigation_suite.sh
#
# One-command runner for the key "fairness and reproducibility" experiments
# requested by external review feedback:
#   1) Storage-only fairness set (includes sqlite + sqlite-optimized + sqlite-precompute)
#   2) Scale benchmark fairness set (same pair + dazzle-precompute/inmemory)
#   3) Optional iOS storage-only mirrors
#   4) Automatic table regeneration via analyze_results.py
#
# Usage examples:
#   research/scripts/run_reviewer_mitigation_suite.sh
#   research/scripts/run_reviewer_mitigation_suite.sh --count 5 --scale-count 3
#   research/scripts/run_reviewer_mitigation_suite.sh --with-ios
#   research/scripts/run_reviewer_mitigation_suite.sh --ios-only
#   research/scripts/run_reviewer_mitigation_suite.sh --android-only
#   research/scripts/run_reviewer_mitigation_suite.sh --results research/benchmarks/results
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results"
COUNT=10
SCALE_COUNT=5
WITH_IOS=false
RUN_ANDROID=true
WITH_VECTOR_SQLITE_FAMILY=false
ANDROID_BACKENDS="dazzle-precompute,sqlite,sqlite-optimized,sqlite-precompute,inmemory,objectbox"
SCALE_BACKENDS="dazzle-precompute,sqlite,sqlite-optimized,sqlite-precompute,inmemory"
IOS_BACKENDS="dazzle-precompute,sqlite,sqlite-optimized,inmemory"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)         COUNT="$2"; shift 2 ;;
        --scale-count)   SCALE_COUNT="$2"; shift 2 ;;
        --results)       RESULTS_DIR="$2"; shift 2 ;;
        --with-ios)      WITH_IOS=true; shift ;;
        --with-vector-sqlite-family) WITH_VECTOR_SQLITE_FAMILY=true; shift ;;
        --ios-only)      RUN_ANDROID=false; WITH_IOS=true; shift ;;
        --android-only)  RUN_ANDROID=true; WITH_IOS=false; shift ;;
        -h|--help)
            sed -n '17,40p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

log "Reviewer mitigation suite: start"
log "results dir: $RESULTS_DIR"
log "storage-only runs/backend: $COUNT"
log "scale runs/backend: $SCALE_COUNT"

if $RUN_ANDROID; then
    log "Step 1/4: Android storage-only fairness set"
    "$REPO_ROOT/research/scripts/run_all_backends.sh" \
        --storage-only \
        --count "$COUNT" \
        --backends "$ANDROID_BACKENDS" \
        --results "$RESULTS_DIR"

    log "Step 2/4: Android scale fairness set"
    "$REPO_ROOT/research/scripts/run_full_benchmark.sh" \
        --scale \
        --count "$SCALE_COUNT" \
        --backends "$SCALE_BACKENDS" \
        --results "$RESULTS_DIR"
else
    log "Step 1/4 + 2/4: Android phases skipped (--ios-only)"
fi

if $WITH_IOS; then
    log "Step 3/4: iOS storage-only fairness mirror"
    "$REPO_ROOT/research/scripts/run_ios_benchmark.sh" \
        --storage-only \
        --count "$COUNT" \
        --backends "$IOS_BACKENDS" \
        --results "$RESULTS_DIR"
else
    log "Step 3/4: iOS mirror skipped (enable with --with-ios)"
fi

log "Step 4/4: regenerate markdown/latex tables per device directory"
find "$RESULTS_DIR" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r device_dir; do
    log "  analyzing: $device_dir"
    python3 "$REPO_ROOT/research/scripts/analyze_results.py" "$device_dir"
done

if $WITH_VECTOR_SQLITE_FAMILY; then
    log "Step 5/5: vector SQLite-family variants (default/optimized/precompute)"
    "$REPO_ROOT/research/scripts/run_vector_sqlite_family.sh" \
        --rounds "$SCALE_COUNT" \
        --results "$RESULTS_DIR/vector_sqlite_family"
fi

log "Reviewer mitigation suite: done"
log "Next: update paper tables from research/benchmarks/results/*"
