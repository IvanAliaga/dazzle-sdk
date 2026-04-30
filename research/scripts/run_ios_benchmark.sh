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
# run_ios_benchmark.sh — iOS storage-only benchmark automation.
#
# Runs storage-only tests across backends on an iPhone connected via
# xcrun devicectl. Results are pulled to experiment/results/<device>/.
#
# Usage:
#   # Storage-only: all iOS backends × 10 runs
#   scripts/run_ios_benchmark.sh --storage-only --count 10
#
#   # Scale benchmark: retrieval vs N on one backend
#   scripts/run_ios_benchmark.sh --scale --backends sqlite --count 3 \
#     --scale-counts 200,1000,5000,20000
#
#   # Specific backends
#   scripts/run_ios_benchmark.sh --storage-only --count 5 \
#     --backends dazzle,dazzle-precompute,valkey,sqlite,sqlite-optimized,inmemory
#
#   # Specify device explicitly
#   scripts/run_ios_benchmark.sh --device 7C7BF335-CC32-5A31-8686-00195459CB50 \
#     --storage-only --count 10
#
#   # Full Gemma experiment
#   scripts/run_ios_benchmark.sh --count 5 --backends dazzle,valkey,sqlite,sqlite-optimized,inmemory
#
# Flags:
#   --device        CoreDevice ID (default: first connected iPhone)
#   --count         Runs per backend (default: 10 for storage-only, 5 for full)
#   --backends      Comma-separated list
#   --storage-only  Run without Gemma (fast retrieval/ingest test)
#   --timeout       Per-run timeout in seconds (default: 120 for storage-only, 900 for full)
#   --results       Output directory (default: experiment/results)
#   --dataset       Dataset resource name without .json (storage-only mode),
#                   e.g. dataset_iot_baseline (200 readings) or dataset_v3 (400 readings)
#   --scale         Run iOS scale benchmark mode
#   --scale-counts  Comma-separated N values for scale mode
#
set -euo pipefail

ALL_BACKENDS="dazzle,dazzle-pipeline,dazzle-precompute,dazzle-lua,dazzle-hfe,dazzle-hll,valkey,sqlite,sqlite-optimized,inmemory"
COUNT=""
BACKENDS="$ALL_BACKENDS"
TIMEOUT=""
STORAGE_ONLY=false
SCALE=false
DEVICE=""
DATASET_NAME=""
SCALE_COUNTS="200,1000,5000,20000"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results"
BUNDLE_ID="io.dazzle.experiment.storage"
MARKER_NAME="experiment_ios_complete.marker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)       DEVICE="$2";       shift 2 ;;
        --count)        COUNT="$2";        shift 2 ;;
        --backends)     BACKENDS="$2";     shift 2 ;;
        --timeout)      TIMEOUT="$2";      shift 2 ;;
        --results)      RESULTS_DIR="$2";  shift 2 ;;
        --dataset)      DATASET_NAME="$2"; shift 2 ;;
        --storage-only) STORAGE_ONLY=true; shift ;;
        --scale)        SCALE=true;        shift ;;
        --scale-counts) SCALE_COUNTS="$2"; shift 2 ;;
        -h|--help)      sed -n '3,27p' "$0"; exit 0 ;;
        *)              echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Defaults
if [[ -z "$COUNT" ]]; then
    if $SCALE; then COUNT=3
    elif $STORAGE_ONLY; then COUNT=10
    else COUNT=5
    fi
fi
if [[ -z "$TIMEOUT" ]]; then
    if $SCALE; then TIMEOUT=600
    elif $STORAGE_ONLY; then TIMEOUT=120
    else TIMEOUT=900
    fi
fi

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

expected_backend_label() {
    case "$1" in
        dazzle)            echo "Dazzle" ;;
        dazzle-pipeline)   echo "Dazzle-Pipeline" ;;
        dazzle-precompute) echo "Dazzle-Precompute" ;;
        dazzle-lua)        echo "Dazzle-Lua" ;;
        dazzle-hfe)        echo "Dazzle-HFE" ;;
        dazzle-hll)        echo "Dazzle-HLL" ;;
        dazzle-vector)     echo "Dazzle-Vector" ;;
        valkey)            echo "Valkey" ;;
        sqlite)            echo "SQLite" ;;
        sqlite-optimized)  echo "SQLite-Optimized" ;;
        lmdb)              echo "LMDB" ;;
        rocksdb)           echo "RocksDB" ;;
        inmemory)          echo "InMemory" ;;
        *)                 echo "" ;;
    esac
}

# validate_json_backend <json_file> <backend_key>
# Ensures the JSON's "backend" label matches the requested backend key.
# This catches stale app binaries that silently fall back to another backend.
validate_json_backend() {
    local json_file="$1"
    local backend_key="$2"
    local expected
    expected="$(expected_backend_label "$backend_key")"
    [[ -z "$expected" ]] && return 0

    local actual
    actual=$(
        python3 - "$json_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(str(data.get("backend", "")))
except Exception:
    print("")
PY
    )
    if [[ "$actual" != "$expected" ]]; then
        warn "  backend label mismatch: expected '$expected' for key '$backend_key', got '$actual'"
        return 1
    fi
    return 0
}

# ── Device detection ─────────────────────────────────────────────────────
command -v xcrun >/dev/null || fail "xcrun not in PATH"

if [[ -z "$DEVICE" ]]; then
    # Find first connected iPhone
    DEVICE=$(xcrun devicectl list devices 2>/dev/null \
        | grep -i "iphone" \
        | head -1 \
        | awk '{for(i=NF;i>=1;i--){if($i ~ /^[A-F0-9]{8}-/){print $i;exit}}}' \
        || true)
fi
[[ -z "$DEVICE" ]] && fail "no iOS device found. Connect an iPhone and try again."
log "CoreDevice ID: $DEVICE"

IFS=',' read -ra BACKEND_LIST <<< "$BACKENDS"

MODE=$($STORAGE_ONLY && echo "storage_only" || echo "full")
if $SCALE; then MODE="scale"; fi
log "mode: $MODE"
log "backends: ${BACKEND_LIST[*]}"
log "count per backend: $COUNT"
log "total runs: $(( ${#BACKEND_LIST[@]} * COUNT ))"
if [[ -n "$DATASET_NAME" ]]; then
    log "dataset override: $DATASET_NAME"
fi
if $SCALE; then
    log "scale counts: $SCALE_COUNTS"
fi

# ── Results directory ────────────────────────────────────────────────────
DEVICE_RESULTS="$RESULTS_DIR/iPhone_12_Pro"
mkdir -p "$DEVICE_RESULTS"

TOTAL_PULLED=0
START_TIME=$(date +%s)

# ── Helpers: talk to device Documents/ ───────────────────────────────────

# pull_documents <dest_dir>
# Copies the app's Documents/ into <dest_dir> and prints the REAL directory
# that contains the files. Xcode 15 drops files inside <dest>/Documents,
# Xcode 26 drops them directly under <dest>. Caller handles both shapes.
pull_documents() {
    local dst="$1"
    xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents \
        --destination "$dst" >/dev/null 2>&1 || return 1
    if [[ -d "$dst/Documents" ]]; then
        printf '%s' "$dst/Documents"
    else
        printf '%s' "$dst"
    fi
}

# read_marker — returns the marker file contents for the current device
# (via an in-process pull into a scratch dir). Empty string if missing.
read_marker() {
    local scratch
    scratch=$(mktemp -d)
    local root
    if ! root=$(pull_documents "$scratch"); then
        rm -rf "$scratch"; return 0
    fi
    [[ -f "$root/$MARKER_NAME" ]] && cat "$root/$MARKER_NAME" || true
    rm -rf "$scratch"
}

# Copy JSONs matching `storageonly_<safe_key>_*.json` or `scale_<safe_key>_*.json` from Documents/ into
# <dest_dir>, but only for files whose trailing timestamp is newer than
# <min_ts>. Returns 0 if at least one file was pulled, 1 otherwise.
pull_latest_json() {
    local dest_dir="$1"
    local backend_key="$2"
    local min_ts="${3:-0}"
    local safe_key
    safe_key=$(printf '%s' "$backend_key" | tr -c 'a-zA-Z0-9_-' '_')
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local root
    if ! root=$(pull_documents "$tmp_dir"); then
        warn "  failed to pull Documents — devicectl error"
        rm -rf "$tmp_dir"
        return 1
    fi

    local pulled_any=1
    # shellcheck disable=SC2206
    local matches=( "$root"/storageonly_${safe_key}_*.json "$root"/scale_${safe_key}_*.json "$root"/experiment_ios_${safe_key}_*.json )
    for f in "${matches[@]}"; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f")
        local ts
        ts=$(printf '%s' "$base" | sed -E 's/^.*_([0-9]+)\.json$/\1/')
        if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts <= min_ts )); then
            continue
        fi
        if [[ ! -f "$dest_dir/$base" ]]; then
            if ! validate_json_backend "$f" "$backend_key"; then
                warn "  skipping mismatched JSON: $base"
                continue
            fi
            cp "$f" "$dest_dir/$base"
            TOTAL_PULLED=$((TOTAL_PULLED + 1))
            log "  pulled: $base"
            pulled_any=0
        fi
    done
    rm -rf "$tmp_dir"
    return "$pulled_any"
}

# ── Main loop ────────────────────────────────────────────────────────────

for BACKEND in "${BACKEND_LIST[@]}"; do
    BACKEND_DIR="$DEVICE_RESULTS/$BACKEND"
    mkdir -p "$BACKEND_DIR"

    log ""
    log "════════════════════════════════════════"
    log "  Backend: $BACKEND  ($COUNT runs, mode=$MODE)"
    log "════════════════════════════════════════"

    for RUN_IDX in $(seq 1 "$COUNT"); do
        log "── $BACKEND run $RUN_IDX / $COUNT ──"

        # Capture the CURRENT marker (content) before launch so we can tell
        # when the app writes a *fresh* one for this run. The marker line
        # looks like `<timestamp_ms> ok storage_only_<backend>`. We track
        # the timestamp prefix; the NEW run wins when its ts exceeds this.
        MARKER_BEFORE=$(read_marker || true)
        TS_BEFORE=$(printf '%s' "$MARKER_BEFORE" | awk 'NR==1{print $1}')
        TS_BEFORE=${TS_BEFORE:-0}

        # Build environment variables JSON
        if $SCALE; then
            ENV_VARS="{\"SCALE_BENCHMARK\":\"true\",\"BACKEND\":\"$BACKEND\",\"SCALE_COUNTS\":\"$SCALE_COUNTS\"}"
            if [[ -n "$DATASET_NAME" ]]; then
                ENV_VARS="{\"SCALE_BENCHMARK\":\"true\",\"BACKEND\":\"$BACKEND\",\"SCALE_COUNTS\":\"$SCALE_COUNTS\",\"DATASET_NAME\":\"$DATASET_NAME\"}"
            fi
        elif $STORAGE_ONLY; then
            if [[ -n "$DATASET_NAME" ]]; then
                ENV_VARS="{\"STORAGE_ONLY\":\"true\",\"BACKEND\":\"$BACKEND\",\"DATASET_NAME\":\"$DATASET_NAME\"}"
            else
                ENV_VARS="{\"STORAGE_ONLY\":\"true\",\"BACKEND\":\"$BACKEND\"}"
            fi
        else
            ENV_VARS="{\"RUN_COUNT\":\"1\",\"BACKEND\":\"$BACKEND\"}"
        fi

        # Launch the app. `--terminate-existing` handles the "previous run
        # is still around" case cleanly; the pre-Xcode-26 script did that
        # dance manually with `process terminate --pid $(…)` which doesn't
        # work when the app already exit(0)'d on its own.
        LAUNCH_ERR="/tmp/dazzle_launch_err.$$"
        xcrun devicectl device process launch \
            --device "$DEVICE" \
            --terminate-existing \
            --environment-variables "$ENV_VARS" \
            "$BUNDLE_ID" 2>"$LAUNCH_ERR" >/dev/null || {
            warn "  failed to launch — $(tr '\n' ' ' < "$LAUNCH_ERR" | head -c 300)"
            rm -f "$LAUNCH_ERR"
            continue
        }
        rm -f "$LAUNCH_ERR"

        # Poll the marker file on device. The app writes the marker AFTER
        # the JSON, right before exit(0) — so seeing a new marker with a
        # ts > TS_BEFORE AND message matching this backend means this run's
        # JSON is already on disk and safe to pull.
        DEADLINE=$(( $(date +%s) + TIMEOUT ))
        POLL_INTERVAL=3
        if ! $STORAGE_ONLY && ! $SCALE; then POLL_INTERVAL=15; fi
        log "  waiting for completion (timeout ${TIMEOUT}s)"

        DONE=false
        while true; do
            if (( $(date +%s) > DEADLINE )); then
                warn "  $BACKEND run $RUN_IDX timed out after ${TIMEOUT}s — skipping"
                break
            fi

            sleep "$POLL_INTERVAL"

            MARKER_NOW=$(read_marker || true)
            TS_NOW=$(printf '%s' "$MARKER_NOW" | awk 'NR==1{print $1}')
            TS_NOW=${TS_NOW:-0}
            MSG_NOW=$(printf '%s' "$MARKER_NOW" | awk 'NR==1{print $3}')

            if [[ "$TS_NOW" =~ ^[0-9]+$ ]] && (( TS_NOW > TS_BEFORE )); then
                EXPECTED_MSG="storage_only_$BACKEND"
                if $SCALE; then
                    EXPECTED_MSG="scale_benchmark_$BACKEND"
                elif ! $STORAGE_ONLY; then
                    EXPECTED_MSG="$MSG_NOW"
                fi
                if [[ "$MSG_NOW" == "$EXPECTED_MSG" ]]; then
                    log "  marker updated (ts=$TS_NOW, msg=$MSG_NOW) — pulling"
                    DONE=true
                    break
                else
                    warn "  marker is for '$MSG_NOW', expected '$EXPECTED_MSG' — waiting"
                fi
            fi
        done

        if $DONE; then
            pull_latest_json "$BACKEND_DIR" "$BACKEND" "$TS_BEFORE" || \
                warn "  marker updated but no matching JSON pulled"
        fi
    done
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

log ""
log "════════════════════════════════════════"
log "  ALL DONE — $TOTAL_PULLED JSON files in ${ELAPSED}s"
log "════════════════════════════════════════"
log "Results: $DEVICE_RESULTS/<backend>/"
