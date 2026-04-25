#!/usr/bin/env bash
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Fetch the LLM model files the Dazzle samples need. Weights are NOT
# checked into the repo — each is ~1–2 GB. Run this once before
# building any sample that uses LlamaCppClient or LiteRtLmClient.
#
#   samples/_scripts/download_models.sh
#
# Files land in samples/_scripts/_models/ :
#     qwen2.5-1.5b-instruct-q4_k_m.gguf    (~1.0 GB) — LlamaCppClient default
#     gemma4-e2b-it.litertlm               (~2.4 GB) — LiteRtLmClient default
#
# Each file is SHA-256 pinned. On checksum mismatch the download is
# rejected — bump the pin here in lockstep with the URL if upstream
# republishes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DST="$HERE/_models"
mkdir -p "$DST"

# ── Qwen 2.5 1.5B Instruct, Q4_K_M ─────────────────────────────────────────
QWEN_URL="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true"
QWEN_FILE="$DST/qwen2.5-1.5b-instruct-q4_k_m.gguf"
# Bump in lockstep with the URL. When blank, the script warns but
# proceeds (useful during the first download; pin after you verify).
QWEN_SHA256=""

# ── Gemma 4 E2B IT (LiteRT) ────────────────────────────────────────────────
# Note: Google distributes LiteRT weights through Kaggle Models; you
# need to accept their license and generate a download URL. Export
# GEMMA_LITERT_URL before running this script, or fetch manually and
# drop the .litertlm file into $DST.
GEMMA_URL="${GEMMA_LITERT_URL:-}"
GEMMA_FILE="$DST/gemma4-e2b-it.litertlm"
GEMMA_SHA256=""

fetch() {
    local url="$1" dst="$2" expected="${3:-}"

    if [[ -f "$dst" ]]; then
        if [[ -n "$expected" ]]; then
            local actual
            actual=$(shasum -a 256 "$dst" | awk '{print $1}')
            if [[ "$actual" == "$expected" ]]; then
                echo "[dl] $(basename "$dst") already present (sha256 OK)"
                return 0
            fi
            echo "[dl] $(basename "$dst") sha256 mismatch — re-downloading"
            rm -f "$dst"
        else
            echo "[dl] $(basename "$dst") already present — skipping"
            return 0
        fi
    fi

    echo "[dl] fetching $(basename "$dst") from $url"
    curl -fL --progress-bar "$url" -o "$dst.part"
    mv "$dst.part" "$dst"

    if [[ -n "$expected" ]]; then
        local actual
        actual=$(shasum -a 256 "$dst" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            echo "[dl] sha256 mismatch on $(basename "$dst")"
            echo "     expected: $expected"
            echo "     actual:   $actual"
            rm -f "$dst"
            exit 1
        fi
        echo "[dl] sha256 OK"
    else
        echo "[dl] (no pinned sha256 — recording $(shasum -a 256 "$dst" | awk '{print $1}'))"
    fi
}

echo "=== Dazzle samples — model download ==="
fetch "$QWEN_URL" "$QWEN_FILE" "$QWEN_SHA256"

if [[ -z "$GEMMA_URL" ]]; then
    cat <<EOF

[dl] SKIPPING Gemma 4 E2B LiteRT — requires a Kaggle-gated URL.
     To enable the LiteRtLmClient adapter:
       1. Accept the Gemma license at https://www.kaggle.com/models/google/gemma
       2. Export GEMMA_LITERT_URL="<your signed URL>" and re-run this script,
          or drop the .litertlm file into:
              $GEMMA_FILE
EOF
else
    fetch "$GEMMA_URL" "$GEMMA_FILE" "$GEMMA_SHA256"
fi

echo
echo "=== Models ready in $DST ==="
ls -lh "$DST"

echo
cat <<EOF

Next:
  iOS  — add the .gguf / .litertlm to the Xcode project's Resources
         and it will bundle on build. The sample project.yml already
         pulls the Resources/ directory, so just drop the file there:

             cp $QWEN_FILE samples/chat-memory/ios/Resources/
             cp $QWEN_FILE samples/chat-iot/ios/Resources/
             cp $QWEN_FILE samples/chat-kb/ios/Resources/

  Android — push to the device (one file, all samples share it):

             adb push $QWEN_FILE /data/local/tmp/
EOF
