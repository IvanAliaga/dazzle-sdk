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
# allTestDevicesAndroidAndIos.sh
#
# Runs the dazzle-vector LLM experiment on every connected device
# (up to 4 Android chips + 1 iOS), collects results, and prints a
# side-by-side comparison table.
#
# Android devices (identified by serial):
#   Kirin    — 6NUDU18424001121  (Huawei ANE-LX3, hi6250, Android 9)
#   MediaTek — QVHNW21B23010674  (FRL-L23, MT6769, Android 10)
#   Unisoc   — ZE223FPXBS        (Moto g35 5G, T760, Android 14)
#   Snapdragon — auto-detected (any connected device not listed above)
#
# iOS: first connected iPhone found via xcrun devicectl.
#
# Usage:
#   research/scripts/allTestDevicesAndroidAndIos.sh
#   research/scripts/allTestDevicesAndroidAndIos.sh --backend dazzle-vector
#   research/scripts/allTestDevicesAndroidAndIos.sh --count 3
#   research/scripts/allTestDevicesAndroidAndIos.sh --timeout 5400
#   research/scripts/allTestDevicesAndroidAndIos.sh --no-ios
#   research/scripts/allTestDevicesAndroidAndIos.sh --no-android
#
# Flags:
#   --backend   experiment backend name (default: dazzle-vector)
#   --count     runs per device (default: 1)
#   --timeout   per-device overall timeout in seconds (default: 4800)
#   --results   output directory (default: research/benchmarks/results)
#   --no-ios    skip iOS
#   --no-android skip Android
#
# Each device runs in parallel. The script waits for all to complete,
# then prints a comparison table.

set -euo pipefail

BACKEND="dazzle-vector"
COUNT=1
TIMEOUT=4800
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="$REPO_ROOT/research/benchmarks/results"
ANDROID_PKG="dev.dazzle.experiment"
IOS_BUNDLE="io.dazzle.experiment"
SKIP_IOS=false
SKIP_ANDROID=false

# Known Android device serials → chip family
declare -A KNOWN_CHIPS=(
    [6NUDU18424001121]="Kirin"
    [QVHNW21B23010674]="MediaTek"
    [ZE223FPXBS]="Unisoc"
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)    BACKEND="$2";      shift 2 ;;
        --count)      COUNT="$2";        shift 2 ;;
        --timeout)    TIMEOUT="$2";      shift 2 ;;
        --results)    RESULTS_DIR="$2";  shift 2 ;;
        --no-ios)     SKIP_IOS=true;     shift ;;
        --no-android) SKIP_ANDROID=true; shift ;;
        -h|--help)    sed -n '3,45p' "$0"; exit 0 ;;
        *)            echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

MARKER_REMOTE="/sdcard/Documents/experiment_android_complete.marker"
MARKER_REMOTE_ALT="/sdcard/Documents/experiment_android_complete.marker"

# ── Temp directory for per-device log files ─────────────────────────────────
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ── Result tracking ──────────────────────────────────────────────────────────
# Each device writes its pulled JSON path to $TMPDIR_RUN/<chip>.result
# or $TMPDIR_RUN/<chip>.error on failure.

# ────────────────────────────────────────────────────────────────────────────
# run_android_device <serial> <chip_name>
# Runs COUNT experiments on the device and pulls the result JSON(s).
# Writes chip.result with paths of pulled JSONs, or chip.error on failure.
# ────────────────────────────────────────────────────────────────────────────
run_android_device() {
    local serial="$1"
    local chip="$2"
    local dest="$RESULTS_DIR/android"
    local logfile="$TMPDIR_RUN/${chip}.log"
    local result_file="$TMPDIR_RUN/${chip}.result"
    local error_file="$TMPDIR_RUN/${chip}.error"

    mkdir -p "$dest"

    _log() { echo "[$(date +%H:%M:%S)] [$chip] $*" | tee -a "$logfile"; }

    _log "starting — serial=$serial backend=$BACKEND count=$COUNT"

    # Verify app is installed
    if ! adb -s "$serial" shell pm list packages 2>/dev/null | grep -q "package:$ANDROID_PKG"; then
        echo "$chip: $ANDROID_PKG not installed" > "$error_file"
        _log "ERROR: app not installed"
        return 1
    fi

    # Snapshot existing JSONs for this backend so we only pull new ones
    local safe_backend
    safe_backend=$(printf '%s' "$BACKEND" | tr -c 'a-zA-Z0-9_-' '_')
    local glob_remote="/sdcard/Documents/experiment_android_${safe_backend}_*.json"
    # Fall back to the generic glob used by older app versions
    local glob_generic="/sdcard/Documents/experiment_android_*.json"
    local existing
    existing=$(adb -s "$serial" shell "ls $glob_remote 2>/dev/null; ls $glob_generic 2>/dev/null" \
        | sort -u | tr -d '\r' || true)

    local pulled_paths=()

    for run_idx in $(seq 1 "$COUNT"); do
        _log "run $run_idx / $COUNT"

        # Clean slate
        adb -s "$serial" shell "am force-stop $ANDROID_PKG" >/dev/null 2>&1 || true
        adb -s "$serial" shell "rm -f $MARKER_REMOTE"        >/dev/null 2>&1 || true

        # Launch
        adb -s "$serial" shell am start \
            -n "$ANDROID_PKG/.ExperimentActivity" \
            --ez auto_run true \
            --ei run_count 1 \
            --es backend "$BACKEND" >/dev/null 2>&1

        # Poll for completion marker
        local deadline=$(( $(date +%s) + TIMEOUT ))
        _log "waiting for marker (timeout ${TIMEOUT}s)"
        while true; do
            if (( $(date +%s) > deadline )); then
                echo "$chip: run $run_idx timed out after ${TIMEOUT}s" > "$error_file"
                _log "TIMEOUT"
                return 1
            fi
            local marker
            # Android 10 devices (e.g. MediaTek) may write to filesDir instead of /sdcard
            marker=$(adb -s "$serial" shell "cat $MARKER_REMOTE 2>/dev/null" | tr -d '\r' || true)
            if [[ -z "$marker" ]]; then
                # Also check app's internal filesDir (Android 10 fallback)
                marker=$(adb -s "$serial" shell \
                    "run-as $ANDROID_PKG cat /data/user/0/$ANDROID_PKG/files/experiment_android_complete.marker 2>/dev/null" \
                    | tr -d '\r' || true)
            fi
            if [[ -n "$marker" ]]; then
                _log "marker: $marker"
                [[ "$marker" != *" ok "* ]] && _log "WARNING: non-ok status in marker"
                break
            fi
            sleep 15
        done
    done

    # Pull new JSONs
    local all_now
    all_now=$(adb -s "$serial" shell "ls $glob_remote 2>/dev/null; ls $glob_generic 2>/dev/null" \
        | sort -u | tr -d '\r' || true)

    # Also check filesDir for Android 10 devices
    local all_filesdir
    all_filesdir=$(adb -s "$serial" shell \
        "run-as $ANDROID_PKG ls /data/user/0/$ANDROID_PKG/files/ 2>/dev/null" \
        | grep "experiment_android_" | tr -d '\r' \
        | sed "s|^|/data/user/0/$ANDROID_PKG/files/|" || true)
    if [[ -n "$all_filesdir" ]]; then
        all_now=$(printf '%s\n%s' "$all_now" "$all_filesdir" | sort -u)
    fi

    local pulled=0
    while IFS= read -r remote_path; do
        [[ -z "$remote_path" ]] && continue
        if ! grep -Fxq "$remote_path" <<<"$existing"; then
            local base
            base=$(basename "$remote_path")
            local local_path="$dest/$base"
            if [[ "$remote_path" == /data/user/0/* ]]; then
                adb -s "$serial" shell "run-as $ANDROID_PKG cat $remote_path" > "$local_path" 2>/dev/null \
                    || { _log "WARNING: could not pull $remote_path"; continue; }
            else
                adb -s "$serial" pull "$remote_path" "$local_path" >/dev/null 2>&1 \
                    || { _log "WARNING: could not pull $remote_path"; continue; }
            fi
            pulled_paths+=("$local_path")
            pulled=$((pulled + 1))
            _log "pulled: $base"
        fi
    done <<<"$all_now"

    if [[ $pulled -eq 0 ]]; then
        echo "$chip: no new JSON files found after experiment" > "$error_file"
        _log "ERROR: no result files found"
        return 1
    fi

    printf '%s\n' "${pulled_paths[@]}" > "$result_file"
    _log "done — $pulled JSON file(s)"
}

# ────────────────────────────────────────────────────────────────────────────
# run_ios_device <core_device_id>
# ────────────────────────────────────────────────────────────────────────────
run_ios_device() {
    local dev_id="$1"
    local chip="iOS-A"
    local dest="$RESULTS_DIR/ios"
    local logfile="$TMPDIR_RUN/${chip}.log"
    local result_file="$TMPDIR_RUN/${chip}.result"
    local error_file="$TMPDIR_RUN/${chip}.error"

    mkdir -p "$dest"

    _log() { echo "[$(date +%H:%M:%S)] [$chip] $*" | tee -a "$logfile"; }

    _log "starting — device=$dev_id backend=$BACKEND count=$COUNT"

    local pre_pull marker_probe pull_dir post_snapshot pre_snapshot
    pre_pull=$(mktemp -d)
    pull_dir=$(mktemp -d)
    marker_probe=$(mktemp -d)
    pre_snapshot=$(mktemp)
    post_snapshot=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -rf '$pre_pull' '$pull_dir' '$marker_probe'; rm -f '$pre_snapshot' '$post_snapshot'" RETURN

    # Snapshot existing JSONs
    xcrun devicectl device copy from \
        --device "$dev_id" \
        --domain-type appDataContainer \
        --domain-identifier "$IOS_BUNDLE" \
        --user mobile \
        --source "Documents" \
        --destination "$pre_pull" \
        --quiet 2>/dev/null || true
    (cd "$pre_pull" 2>/dev/null && find . -name 'experiment_ios_*.json' -type f -print 2>/dev/null \
        | sed 's|^\./||') | sort > "$pre_snapshot"

    local pulled_paths=()

    for run_idx in $(seq 1 "$COUNT"); do
        _log "run $run_idx / $COUNT"

        xcrun devicectl device process terminate \
            --device "$dev_id" \
            --bundle-identifier "$IOS_BUNDLE" >/dev/null 2>&1 || true

        xcrun devicectl device process launch \
            --device "$dev_id" \
            --terminate-existing \
            --environment-variables "{\"RUN_COUNT\":\"1\",\"BACKEND\":\"$BACKEND\"}" \
            "$IOS_BUNDLE" >/dev/null 2>&1 \
            || { echo "$chip: failed to launch app" > "$error_file"; return 1; }

        local deadline=$(( $(date +%s) + TIMEOUT ))
        rm -f "$marker_probe/experiment_ios_complete.marker"
        _log "waiting for marker (timeout ${TIMEOUT}s)"
        while true; do
            if (( $(date +%s) > deadline )); then
                echo "$chip: run $run_idx timed out" > "$error_file"
                _log "TIMEOUT"
                return 1
            fi
            if xcrun devicectl device copy from \
                --device "$dev_id" \
                --domain-type appDataContainer \
                --domain-identifier "$IOS_BUNDLE" \
                --user mobile \
                --source "Documents/experiment_ios_complete.marker" \
                --destination "$marker_probe/" \
                --quiet 2>/dev/null; then
                local marker_body
                marker_body=$(cat "$marker_probe/experiment_ios_complete.marker" 2>/dev/null || echo "")
                _log "marker: $marker_body"
                [[ "$marker_body" != *" ok "* ]] && _log "WARNING: non-ok"
                break
            fi
            sleep 15
        done
    done

    # Pull results
    xcrun devicectl device copy from \
        --device "$dev_id" \
        --domain-type appDataContainer \
        --domain-identifier "$IOS_BUNDLE" \
        --user mobile \
        --source "Documents" \
        --destination "$pull_dir" \
        --quiet 2>/dev/null || { echo "$chip: failed to pull results" > "$error_file"; return 1; }

    (cd "$pull_dir" && find . -name 'experiment_ios_*.json' -type f -print \
        | sed 's|^\./||') | sort > "$post_snapshot"

    local pulled=0
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if ! grep -Fxq "$rel" "$pre_snapshot"; then
            local src="$pull_dir/$rel"
            local base; base=$(basename "$rel")
            local local_path="$dest/$base"
            [[ -f "$src" ]] && cp "$src" "$local_path" && \
                pulled_paths+=("$local_path") && pulled=$((pulled + 1))
            _log "pulled: $base"
        fi
    done < "$post_snapshot"

    if [[ $pulled -eq 0 ]]; then
        echo "$chip: no new JSON files" > "$error_file"
        return 1
    fi
    printf '%s\n' "${pulled_paths[@]}" > "$result_file"
    _log "done — $pulled JSON file(s)"
}

# ────────────────────────────────────────────────────────────────────────────
# compare_results — parse all pulled JSONs and print a table
# ────────────────────────────────────────────────────────────────────────────
compare_results() {
    local json_paths=("$@")
    [[ ${#json_paths[@]} -eq 0 ]] && { warn "no result files to compare"; return; }

    python3 - "${json_paths[@]}" <<'PY'
import json, sys, os

files = sys.argv[1:]

rows = []
for path in files:
    if not os.path.isfile(path):
        continue
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception as e:
        print(f"  [warn] could not parse {path}: {e}", file=sys.stderr)
        continue

    m = d.get("metrics", {})
    di = d.get("device_info", {})
    cps = d.get("checkpoints", [])

    # Derive FP / FN from checkpoints when available
    fp = fn = tp = tn = 0
    for cp in cps:
        has_anomaly = cp.get("window_has_anomaly", False)
        aug = cp.get("augmented", {})
        # Android uses bool 'detected'; iOS may use str 'anomaly'
        det = aug.get("detected", aug.get("anomaly", "no"))
        classified_anomaly = det if isinstance(det, bool) else str(det).lower() == "yes"
        if has_anomaly and classified_anomaly:     tp += 1
        elif has_anomaly and not classified_anomaly: fn += 1
        elif not has_anomaly and classified_anomaly: fp += 1
        else:                                        tn += 1

    total_cps = len(cps)
    recall = tp / (tp + fn) if (tp + fn) > 0 else float("nan")
    precision = tp / (tp + fp) if (tp + fp) > 0 else float("nan")
    fpr = fp / (fp + tn) if (fp + tn) > 0 else float("nan")

    # Fall back to summary metrics when checkpoints lack augmented decisions
    if total_cps > 0 and (tp + fn + fp + tn) == 0:
        recall = m.get("recall_augmented", float("nan"))
        fpr    = m.get("fpr_augmented", float("nan"))
        fp = fn = tp = tn = -1

    device_model = d.get("device", di.get("model", "?"))
    platform = d.get("platform", "Android")
    backend  = d.get("backend", "?")
    ts       = d.get("timestamp", "?")[:16]
    inf_ms   = m.get("avg_inference_ms_b", m.get("avg_inference_ms_a", float("nan")))
    abi      = di.get("abi", "?")
    ram_gb   = di.get("ram_total_kb", 0) / (1024 * 1024)
    android_v = di.get("android_version", di.get("os_version", "?"))

    rows.append({
        "device": device_model,
        "platform": platform,
        "backend": backend,
        "timestamp": ts,
        "TP": tp, "TN": tn, "FP": fp, "FN": fn,
        "recall": recall,
        "precision": precision,
        "fpr": fpr,
        "inf_ms": inf_ms,
        "abi": abi,
        "ram_gb": ram_gb,
        "android_v": android_v,
    })

if not rows:
    print("no rows parsed")
    sys.exit(0)

# Sort by recall desc, fpr asc
rows.sort(key=lambda r: (-r["recall"] if r["recall"] == r["recall"] else 0,
                          r["fpr"]    if r["fpr"]    == r["fpr"]    else 1))

W_DEV = max(len(r["device"]) for r in rows)
W_DEV = max(W_DEV, 6)

hdr = (f"{'Device':<{W_DEV}}  {'Backend':<16}  "
       f"{'TP':>3}  {'TN':>3}  {'FP':>3}  {'FN':>3}  "
       f"{'Recall':>7}  {'Prec':>7}  {'FPR':>7}  "
       f"{'Inf(ms)':>8}  {'ABI':<10}  {'RAM':>5}  {'OS':<5}")
sep = "─" * len(hdr)

print()
print("╔" + "═" * len(hdr) + "╗")
print("║" + f"  dazzle-vector Experiment — Cross-Device Comparison".center(len(hdr)) + "║")
print("╠" + "═" * len(hdr) + "╣")
print("║ " + hdr + " ║")
print("║ " + sep + " ║")

for r in rows:
    def fmt_f(v, w=7):
        return f"{v:{w}.3f}" if v == v else f"{'n/a':>{w}}"
    def fmt_i(v, w=3):
        return f"{v:{w}d}" if v >= 0 else f"{'n/a':>{w}}"
    line = (f"{r['device']:<{W_DEV}}  {r['backend']:<16}  "
            f"{fmt_i(r['TP'])}  {fmt_i(r['TN'])}  {fmt_i(r['FP'])}  {fmt_i(r['FN'])}  "
            f"{fmt_f(r['recall'])}  {fmt_f(r['precision'])}  {fmt_f(r['fpr'])}  "
            f"{fmt_f(r['inf_ms'], 8)}  {r['abi']:<10}  {r['ram_gb']:>5.1f}  {r['android_v']:<5}")
    print("║ " + line + " ║")

print("╚" + "═" * len(hdr) + "╝")
print()

# Highlight best recall
best_recall = max(r["recall"] for r in rows if r["recall"] == r["recall"])
best_device = next(r["device"] for r in rows if r["recall"] == best_recall)
print(f"  Best recall : {best_recall:.3f}  ({best_device})")
lowest_fpr = min(r["fpr"] for r in rows if r["fpr"] == r["fpr"])
low_device = next(r["device"] for r in rows if r["fpr"] == lowest_fpr)
print(f"  Lowest FPR  : {lowest_fpr:.3f}  ({low_device})")
print()
PY
}

# ────────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────────

log "══════════════════════════════════════════════════════"
log "  allTestDevicesAndroidAndIos  — backend=$BACKEND  count=$COUNT"
log "══════════════════════════════════════════════════════"

mkdir -p "$RESULTS_DIR/android" "$RESULTS_DIR/ios"

declare -a PIDS=()
declare -a CHIPS_RAN=()

# ── Android ──────────────────────────────────────────────────────────────────
if ! $SKIP_ANDROID; then
    command -v adb >/dev/null || fail "adb not found in PATH"
    all_serials=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

    if [[ -z "$all_serials" ]]; then
        warn "no Android devices connected"
    else
        while IFS= read -r serial; do
            [[ -z "$serial" ]] && continue
            chip="${KNOWN_CHIPS[$serial]:-Snapdragon}"
            log "found Android device: $serial → $chip"
            CHIPS_RAN+=("$chip")
            run_android_device "$serial" "$chip" &
            PIDS+=($!)
        done <<<"$all_serials"
    fi
fi

# ── iOS ───────────────────────────────────────────────────────────────────────
IOS_DEV_ID=""
if ! $SKIP_IOS && command -v xcrun >/dev/null 2>&1; then
    IOS_DEV_ID=$(xcrun devicectl list devices 2>/dev/null \
        | grep -i "iphone" \
        | head -1 \
        | awk '{for(i=NF;i>=1;i--){if($i ~ /^[A-F0-9-]{36}$/){print $i;exit}}}' \
        || true)
    if [[ -n "$IOS_DEV_ID" ]]; then
        log "found iOS device: $IOS_DEV_ID"
        CHIPS_RAN+=("iOS-A")
        run_ios_device "$IOS_DEV_ID" &
        PIDS+=($!)
    else
        warn "no iOS device found (skipping)"
    fi
elif $SKIP_IOS; then
    log "iOS skipped (--no-ios)"
else
    warn "xcrun not available — skipping iOS"
fi

if [[ ${#PIDS[@]} -eq 0 ]]; then
    fail "no devices to test — connect at least one device and try again"
fi

log "waiting for ${#PIDS[@]} device(s) to complete…"

# Wait for all background jobs
ALL_OK=true
for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    chip="${CHIPS_RAN[$i]}"
    if wait "$pid"; then
        ok "[$chip] finished"
    else
        warn "[$chip] returned error (exit $?)"
        ALL_OK=false
    fi
done

# ── Print per-device logs ─────────────────────────────────────────────────────
echo
log "══ Device logs ══"
for chip in "${CHIPS_RAN[@]}"; do
    logfile="$TMPDIR_RUN/${chip}.log"
    [[ -f "$logfile" ]] && { echo; echo "--- $chip ---"; cat "$logfile"; }
done

# ── Gather all pulled JSON paths ─────────────────────────────────────────────
declare -a ALL_JSONS=()
for chip in "${CHIPS_RAN[@]}"; do
    result_file="$TMPDIR_RUN/${chip}.result"
    error_file="$TMPDIR_RUN/${chip}.error"
    if [[ -f "$result_file" ]]; then
        while IFS= read -r p; do
            [[ -n "$p" && -f "$p" ]] && ALL_JSONS+=("$p")
        done < "$result_file"
    elif [[ -f "$error_file" ]]; then
        warn "[$chip] error: $(cat "$error_file")"
    fi
done

# ── Compare ───────────────────────────────────────────────────────────────────
if [[ ${#ALL_JSONS[@]} -gt 0 ]]; then
    log "══ Comparison ══"
    compare_results "${ALL_JSONS[@]}"
else
    warn "no result JSONs to compare"
fi

log "results saved to: $RESULTS_DIR/android/  $RESULTS_DIR/ios/"

$ALL_OK && ok "all devices completed successfully" || warn "some devices failed — check logs above"
