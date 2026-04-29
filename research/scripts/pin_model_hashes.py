#!/usr/bin/env python3
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

"""Pin SHA256 hashes of the shipped LiteRT-LM models into the manifest.

Usage — the happy path:

    python3 research/scripts/pin_model_hashes.py \\
        --gemma ~/Downloads/gemma-4-E2B-it.litertlm \\
        --llama ~/Downloads/llama-3.2-3b-instruct.litertlm \\
        --qwen  ~/Downloads/qwen-2.5-1.5b-instruct.litertlm

For each file passed, the script:

1. Computes the SHA256 streaming (no full-file load — a 2.4 GB model would
   otherwise balloon RAM).
2. Rewrites the `sha256` field in:
     - `docs/sdk/edge_models.json`     (canonical JSON source of truth)
     - `sdk/android/src/main/java/dev/dazzle/sdk/edge/ModelManifest.kt`
     - `sdk/ios/Sources/edge/ModelManifest.swift`
3. Prints a summary diff so a maintainer can review before committing.

Only the fields for the passed files are updated; unspecified entries
keep whatever hash they already had. Passing `--dry-run` prints the
hashes without modifying any file.

Design note — we ship the SHA256 in three places on purpose. The JSON is
canonical (consumer-readable metadata + CI verification), but the Kotlin
and Swift projections must compile even when the JSON is not on the
classpath at runtime, so each platform carries its own hardcoded
fallback that the downloader checks.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

JSON_PATH   = REPO_ROOT / "docs" / "sdk" / "edge_models.json"
KOTLIN_PATH = REPO_ROOT / "sdk" / "android" / "src" / "main" / "java" / "dev" / "dazzle" / "sdk" / "edge" / "ModelManifest.kt"
SWIFT_PATH  = REPO_ROOT / "sdk" / "ios" / "Sources" / "edge" / "ModelManifest.swift"


@dataclass
class ModelId:
    """Links the `--<flag>` used on the CLI to the identifiers each
    file uses internally. The `manifest_id` matches the JSON key; the
    Kotlin and Swift `<platform>_name` fields name the static property
    declared in the corresponding manifest file so we can locate the
    block to rewrite with a simple regex (no full-parser needed)."""
    flag: str                # CLI flag (without --)
    manifest_id: str         # JSON key + kotlin/swift `id` property
    kotlin_name: str         # static val name in ModelManifest.kt
    swift_name:  str         # static let name in ModelManifest.swift


MODELS = [
    ModelId("gemma", "gemma-4-E2B-it",         "gemma4_E2B",  "gemma4_E2B"),
    ModelId("llama", "llama-3.2-3B-instruct",  "llama32_3B",  "llama32_3B"),
    ModelId("qwen",  "qwen-2.5-1.5b-instruct", "qwen25_1B5B", "qwen25_1B5B"),
]


def sha256_of(path: Path, chunk_size: int = 1 << 20) -> str:
    """Streaming SHA256 — 1 MiB chunks so a 2.4 GB file never
    materialises in RAM. Matches the algorithm the Kotlin and Swift
    downloaders use at runtime (`MessageDigest.getInstance("SHA-256")`
    / `CryptoKit.SHA256`). Bytes are streamed verbatim; no newline
    normalisation, no trimming."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def update_json(hashes: dict[str, str], dry_run: bool) -> None:
    """Patch docs/sdk/edge_models.json in-place (or print the would-be
    diff on dry-run). Preserves the existing field order — json.dump
    with sort_keys=False + the 2-space indent the file already uses."""
    data = json.loads(JSON_PATH.read_text())
    changed = False
    for mid, digest in hashes.items():
        if mid not in data["models"]:
            print(f"warning: {mid} not present in JSON, skipping", file=sys.stderr)
            continue
        if data["models"][mid]["sha256"] != digest:
            data["models"][mid]["sha256"] = digest
            changed = True
            print(f"[json] {mid}: {digest}")
    if dry_run or not changed:
        return
    # Preserve trailing newline + 2-space indent.
    JSON_PATH.write_text(json.dumps(data, indent=2) + "\n")


def update_projection(
    path: Path,
    hashes: dict[str, str],
    id_to_symbol: dict[str, str],
    dry_run: bool,
) -> None:
    """Rewrite the `sha256 = "..."` / `sha256: "..."` literal inside
    the static entry for each known model. The regex anchors on the
    `id` field first so we never accidentally patch a SHA256 that
    belongs to a different entry declared earlier in the same file."""
    src = path.read_text()
    orig = src
    for manifest_id, symbol in id_to_symbol.items():
        digest = hashes.get(manifest_id)
        if digest is None:
            continue
        # Match:  id = "<manifest_id>",    ...    sha256 = "<old>",
        #         (Swift uses `:` instead of `=`; one pattern handles both.)
        pat = re.compile(
            r'(id\s*[:=]\s*"' + re.escape(manifest_id) + r'"'
            r'[^{}]*?sha256\s*[:=]\s*")([A-Za-z0-9_]+)(")',
            re.DOTALL,
        )
        m = pat.search(src)
        if not m:
            print(
                f"warning: could not find sha256 literal for {manifest_id} "
                f"(symbol {symbol}) in {path.name}",
                file=sys.stderr,
            )
            continue
        src = pat.sub(lambda _m: _m.group(1) + digest + _m.group(3), src, count=1)
        print(f"[{path.name}] {manifest_id}: {digest}")
    if dry_run or src == orig:
        return
    path.write_text(src)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for m in MODELS:
        ap.add_argument(
            f"--{m.flag}",
            type=Path,
            help=f"Path to {m.manifest_id}.litertlm",
        )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Compute hashes and print them but do not modify any file",
    )
    args = ap.parse_args()

    # Map flag → (computed digest) only for files actually passed.
    hashes: dict[str, str] = {}
    for m in MODELS:
        path: Path | None = getattr(args, m.flag)
        if path is None:
            continue
        if not path.is_file():
            print(f"error: {path} does not exist or is not a file", file=sys.stderr)
            return 2
        print(f"computing sha256 of {path} …", file=sys.stderr)
        hashes[m.manifest_id] = sha256_of(path)

    if not hashes:
        ap.error("pass at least one of --gemma / --llama / --qwen (or all three)")

    update_json(hashes, args.dry_run)
    update_projection(
        KOTLIN_PATH,
        hashes,
        {m.manifest_id: m.kotlin_name for m in MODELS},
        args.dry_run,
    )
    update_projection(
        SWIFT_PATH,
        hashes,
        {m.manifest_id: m.swift_name for m in MODELS},
        args.dry_run,
    )

    if args.dry_run:
        print("\ndry-run: no files were modified", file=sys.stderr)
    else:
        print("\nAll three projections updated. Review `git diff` and commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
