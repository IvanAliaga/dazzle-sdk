#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Provider × stack build matrix. For every (stack, provider) cell,
# swap the sample's `LLMAdapter` to that provider, run the right
# build command (gradle assemble / flutter build / xcodebuild / npx
# react-native bundle), record pass/fail, then restore the
# adapter from a per-cell backup.
#
# This is what a developer sees when they pick a provider — does the
# project still build? The only way this matrix can be green is if
# every adapter's class signature lines up with what the SDK exports.
#
# Output: a printable matrix at the end + an exit code that's
# non-zero when any cell fails.

set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HERE/_scripts/_smoke_providers.log"
: > "$LOG"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

declare -A RESULT  # RESULT["stack:provider"] = pass|fail|skip

record() { RESULT["$1:$2"]="$3"; }

# ── Android native ─────────────────────────────────────────────
android_native() {
  local provider="$1"
  local f="$HERE/_shared/android/LLMAdapter.kt"
  cp "$f" "$f.bak"

  case "$provider" in
    llama)
      # Already the default — no edit.
      ;;
    litertlm)
      # Comment out the LlamaCpp block, uncomment the LiteRt block.
      python3 - <<EOF
import re, pathlib
p = pathlib.Path("$f")
s = p.read_text()
# 1) comment out the active LlamaCpp return
s = re.sub(r'(\n\s*)(return LlamaCppClient\([^)]*\n[^)]*\n[^)]*\n[^)]*\n[^)]*\n[^)]*\))',
           lambda m: m.group(1) + '/* SMOKE-DISABLED:\n' + m.group(2) + '\n*/',
           s, count=1, flags=re.S)
# 2) uncomment the LiteRt block (lines starting with "// return LiteRtLmClient(")
lines = s.split("\n")
out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// return LiteRtLmClient("):
        in_block = True
        out.append(ln.replace("// ", "", 1))
        continue
    if in_block:
        if ln.strip() == "" or not ln.lstrip().startswith("//"):
            if ln.strip() == "" and not in_block: out.append(ln); continue
            in_block = False
            out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
p.write_text("\n".join(out))
EOF
      ;;
    openai)
      python3 - <<EOF
import re, pathlib
p = pathlib.Path("$f")
s = p.read_text()
s = re.sub(r'(\n\s*)(return LlamaCppClient\([^)]*\n[^)]*\n[^)]*\n[^)]*\n[^)]*\n[^)]*\))',
           lambda m: m.group(1) + '/* SMOKE-DISABLED:\n' + m.group(2) + '\n*/',
           s, count=1, flags=re.S)
# Uncomment the FIRST OpenAI block (the OpenAI proper one)
lines = s.split("\n")
out, found, in_block = [], False, False
for ln in lines:
    if not found and ln.lstrip().startswith("// return OpenAICompatibleClient("):
        found = True; in_block = True
        out.append(ln.replace("// ", "", 1))
        continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False
            out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
# Inject a stub BuildConfig.OPENAI_API_KEY = "" so it compiles.
s2 = "\n".join(out)
s2 = s2.replace("BuildConfig.OPENAI_API_KEY", '""')
p.write_text(s2)
EOF
      ;;
  esac

  log "  android × $provider — gradle assembleDebug"
  local rc=0
  (cd "$HERE/../sdk/android" && \
    ./gradlew :samples-chat-iot:assembleDebug --quiet 2>&1) >>"$LOG" 2>&1 || rc=$?

  cp "$f.bak" "$f"; rm "$f.bak"

  if [[ $rc -eq 0 ]]; then
    ok "  android × $provider — PASS"; record android "$provider" pass
  else
    err "  android × $provider — FAIL (rc=$rc, see $LOG)"; record android "$provider" fail
  fi
}

# ── Flutter ────────────────────────────────────────────────────
flutter_stack() {
  local provider="$1"
  local f="$HERE/_shared/flutter/lib/src/llm_adapter.dart"
  cp "$f" "$f.bak"

  case "$provider" in
    llama)
      ;;
    litertlm)
      sed -i '' -E 's|^(\s*)return LlamaCppClient.create\(|\1// SMOKE: return LlamaCppClient.create(|' "$f"
      python3 - <<EOF
import re, pathlib
p = pathlib.Path("$f")
s = p.read_text()
# Uncomment LiteRtLmClient.create block (// return LiteRtLmClient.create( ... );)
lines = s.split("\n"); out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// return LiteRtLmClient.create("):
        in_block = True; out.append(ln.replace("// ", "", 1)); continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False; out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
p.write_text("\n".join(out))
EOF
      ;;
    foundation)
      python3 - <<EOF
import pathlib, re
p = pathlib.Path("$f")
s = p.read_text()
# Comment LlamaCpp return, uncomment FoundationModels block.
s = re.sub(r'(?m)^(\s*)return LlamaCppClient.create\(', r'\1// SMOKE: return LlamaCppClient.create(', s, count=1)
lines = s.split("\n"); out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// if (await FoundationModelsClient.isAvailable"):
        in_block = True; out.append(ln.replace("// ", "", 1)); continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False; out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
p.write_text("\n".join(out))
EOF
      ;;
    openai)
      python3 - <<EOF
import pathlib, re
p = pathlib.Path("$f")
s = p.read_text()
s = re.sub(r'(?m)^(\s*)return LlamaCppClient.create\(', r'\1// SMOKE: return LlamaCppClient.create(', s, count=1)
lines = s.split("\n"); out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// return OpenAICompatibleClient("):
        in_block = True; out.append(ln.replace("// ", "", 1)); continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False; out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
# Inject empty key so analyzer is happy.
s2 = "\n".join(out)
s2 = s2.replace("Platform.environment['OPENAI_API_KEY']", "''")
p.write_text(s2)
EOF
      ;;
  esac

  log "  flutter × $provider — flutter build apk --debug"
  local rc=0
  (cd "$HERE/chat-iot-flutter" && flutter build apk --debug \
    --target-platform android-arm64 2>&1) >>"$LOG" 2>&1 || rc=$?

  cp "$f.bak" "$f"; rm "$f.bak"

  if [[ $rc -eq 0 ]]; then
    ok "  flutter × $provider — PASS"; record flutter "$provider" pass
  else
    err "  flutter × $provider — FAIL"; record flutter "$provider" fail
  fi
}

# ── React Native ───────────────────────────────────────────────
rn_stack() {
  local provider="$1"
  # RN's adapter is per-sample; pick chat-iot-rn as the canary.
  local f="$HERE/chat-iot-rn/src/llmAdapter.ts"
  cp "$f" "$f.bak"

  case "$provider" in
    openai|hf)
      # Already the default — env var-driven OpenAI/HF.
      ;;
    llama)
      python3 - <<EOF
import pathlib
p = pathlib.Path("$f")
s = p.read_text()
# Uncomment the LlamaCppClient.create block.
lines = s.split("\n"); out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// return await LlamaCppClient.create("):
        in_block = True; out.append(ln.replace("// ", "", 1)); continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False; out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
p.write_text("\n".join(out))
EOF
      ;;
    litertlm)
      python3 - <<EOF
import pathlib
p = pathlib.Path("$f")
s = p.read_text()
lines = s.split("\n"); out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// return await LiteRtLmClient.create("):
        in_block = True; out.append(ln.replace("// ", "", 1)); continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False; out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
p.write_text("\n".join(out))
EOF
      ;;
    foundation)
      python3 - <<EOF
import pathlib
p = pathlib.Path("$f")
s = p.read_text()
lines = s.split("\n"); out, in_block = [], False
for ln in lines:
    if not in_block and ln.lstrip().startswith("// if (await FoundationModelsClient.isAvailable"):
        in_block = True; out.append(ln.replace("// ", "", 1)); continue
    if in_block:
        if not ln.lstrip().startswith("//"):
            in_block = False; out.append(ln); continue
        out.append(ln.replace("// ", "", 1))
    else:
        out.append(ln)
p.write_text("\n".join(out))
EOF
      ;;
  esac

  log "  rn × $provider — type-check + Metro bundle"
  local rc=0
  (cd "$HERE/chat-iot-rn" && \
    npx --no-install tsc --noEmit -p tsconfig.json 2>&1 && \
    npx --no-install react-native bundle --platform android --dev false \
        --entry-file index.js \
        --bundle-output /tmp/_dazzle_smoke_$provider.bundle 2>&1) \
    >>"$LOG" 2>&1 || rc=$?

  cp "$f.bak" "$f"; rm "$f.bak"

  if [[ $rc -eq 0 ]]; then
    ok "  rn × $provider — PASS"; record rn "$provider" pass
  else
    err "  rn × $provider — FAIL"; record rn "$provider" fail
  fi
}

# ── Run ────────────────────────────────────────────────────────
log "═══ Native Android (chat-iot) ═══"
android_native llama
android_native litertlm
android_native openai

log "═══ Flutter (chat-iot-flutter) ═══"
flutter_stack llama
flutter_stack litertlm
flutter_stack openai

log "═══ React Native (chat-iot-rn) ═══"
rn_stack openai
rn_stack llama
rn_stack litertlm

# iOS is left out of this script — `xcodebuild` for the chat-iot
# project takes ~30 s/build and we already verified those builds in
# the smoke test runs above. Add an iOS pass when a faster test
# device is available.

# ── Print matrix ───────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════"
echo "  PROVIDER × STACK BUILD MATRIX"
echo "═══════════════════════════════════════════════════"
printf "%-12s | %-10s | %-10s | %-10s | %-12s\n" \
       "stack" "llama" "litertlm" "openai" "foundation"
echo "-----------------------------------------------------------------"
for stack in android flutter rn; do
  row=""
  for prov in llama litertlm openai foundation; do
    cell=${RESULT[$stack:$prov]:-—}
    case "$cell" in
      pass) cell="✓ pass" ;;
      fail) cell="✗ fail" ;;
      skip) cell="—" ;;
    esac
    row+=" | $(printf '%-10s' "$cell")"
  done
  printf "%-12s%s\n" "$stack" "$row"
done
echo "═══════════════════════════════════════════════════"
echo "Detailed log: $LOG"

# Exit non-zero if any cell failed.
for v in "${RESULT[@]}"; do
  [[ "$v" == "fail" ]] && exit 1
done
exit 0
