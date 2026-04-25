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

# Apply Android Bionic compatibility patches to Valkey source.
#
# Usage: bash apply_patches.sh /path/to/valkey-source
#
# The patches themselves live under versions/<version>/patches/. This
# script only decides which version we're on and whether a patch has
# already been applied (idempotent: CMake calls this every configure).

set -euo pipefail

VALKEY_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# TODO: derive this from DazzleConfig / CMake. For now we only support v9.
VALKEY_VERSION_MAJOR="9"
PATCH_DIR="$REPO_ROOT/versions/v${VALKEY_VERSION_MAJOR}/patches"

# Idempotency — patch-specific sentinels let us cope with a clone that was
# populated before a new patch was added: we skip earlier patches if they
# are in place but still apply newer ones when their sentinel is missing.
have_01_03=0
have_04=0
have_static=0
have_05=0
grep -q "pthread_kill(bwd->bio_thread_id" "$VALKEY_DIR/src/bio.c" 2>/dev/null && have_01_03=1
grep -q "dazzle_tls_current_client"       "$VALKEY_DIR/src/server.h" 2>/dev/null && have_04=1
grep -q "DAZZLE_STATIC_MODULE"            "$VALKEY_DIR/src/module.c" 2>/dev/null && have_static=1
grep -q "Dazzle in-process mode"          "$VALKEY_DIR/src/server.c" 2>/dev/null && have_05=1

if [ "$have_01_03" = "1" ] && [ "$have_04" = "1" ] \
    && [ "$have_static" = "1" ] && [ "$have_05" = "1" ]; then
    echo "Patches already applied, skipping"
    exit 0
fi

echo "Applying Android patches from $PATCH_DIR to $VALKEY_DIR..."

apply() {
    local patch="$1"
    if [ ! -f "$patch" ]; then
        echo "  missing patch: $patch" >&2
        exit 1
    fi
    ( cd "$VALKEY_DIR" && git apply --whitespace=nowarn "$patch" ) \
        || { echo "  failed to apply $(basename "$patch")" >&2; exit 1; }
    echo "  applied $(basename "$patch")"
}

if [ "$have_01_03" = "0" ]; then
    apply "$PATCH_DIR/01_android.patch"
    apply "$PATCH_DIR/03_server_hook.patch"
fi
if [ "$have_04" = "0" ]; then
    apply "$PATCH_DIR/04_threading.patch"
fi
if [ "$have_05" = "0" ]; then
    apply "$PATCH_DIR/05_no_listener.patch"
fi

# ── Static-module loader (cross-platform, Android + iOS) ────────────────────
# Dazzle links every shipped Valkey module (valkey-search, TFI, ...) into
# libdazzle.so — there is no separate .so to dlopen at runtime. To let the
# stock Valkey module loader find them, --loadmodule is passed the sentinel
# `@static:<name>`; we intercept that here and swap in RTLD_DEFAULT + a
# per-module symbol name `ValkeyModule_OnLoad_<name>`.
#
# The substitution is done with perl (Valkey upstream ships LF-only source
# so BSD sed's regex quirks are irrelevant here). Idempotent: the sentinel
# `DAZZLE_STATIC_MODULE` stops re-patching on reconfigure.
if [ "$have_static" = "0" ]; then
    perl -0777 -i -pe '
        s{    handle = dlopen\(path, dlopen_flags\);\n    if \(handle == NULL\) \{\n        serverLog\(LL_WARNING, "Module %s failed to load: %s", path, dlerror\(\)\);\n        return C_ERR;\n    \}\n\n    const char \*onLoadNames\[\] = \{"ValkeyModule_OnLoad", "RedisModule_OnLoad"\};}
         {    /* DAZZLE_STATIC_MODULE: @static:<name> is linked into the host binary.\n     * Resolve via RTLD_DEFAULT and a per-module ValkeyModule_OnLoad_<name>\n     * symbol so multiple static modules can coexist in one process. */\n    char _dazzle_onload_name[128] = \{0\};\n    if (path \&\& strncmp(path, "\@static:", 8) == 0) \{\n        handle = RTLD_DEFAULT;\n        snprintf(_dazzle_onload_name, sizeof(_dazzle_onload_name),\n                 "ValkeyModule_OnLoad_%s", path + 8);\n    \} else \{\n        handle = dlopen(path, dlopen_flags);\n        if (handle == NULL) \{\n            serverLog(LL_WARNING, "Module %s failed to load: %s", path, dlerror());\n            return C_ERR;\n        \}\n    \}\n\n    const char *onLoadNames[] = \{\n        _dazzle_onload_name[0] ? _dazzle_onload_name : "ValkeyModule_OnLoad",\n        "RedisModule_OnLoad",\n    \};}' \
        "$VALKEY_DIR/src/module.c" \
        || { echo "  failed to patch module.c for static modules" >&2; exit 1; }

    if ! grep -q "DAZZLE_STATIC_MODULE" "$VALKEY_DIR/src/module.c"; then
        echo "  static-module patch did not land — upstream module.c shape changed" >&2
        exit 1
    fi
    echo "  applied static-module loader patch"
fi

# Generate release.h (used by Valkey's INFO and version string)
(cd "$VALKEY_DIR/src" && sh mkreleasehdr.sh 2>/dev/null || true)

echo "All patches applied"
