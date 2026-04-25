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

# Dazzle: Cross-compile Valkey for iOS (device + simulator)
# Produces: sdk/ios/Dazzle.xcframework
#
# Usage: bash sdk/ios/build.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
info() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_DIR="$PROJECT_DIR/core"
BUILD_BASE="/tmp/valkey-ios-$$"
OUTPUT_DIR="$SCRIPT_DIR"
MIN_IOS="15.0"
VALKEY_VERSION="9.0.3"
VALKEY_VERSION_MAJOR="${VALKEY_VERSION%%.*}"
PATCH_DIR="$PROJECT_DIR/versions/v${VALKEY_VERSION_MAJOR}/patches"
HNSWLIB_DIR="$BUILD_BASE/hnswlib"

# llama.cpp — bundled as libllama.a into libvalkey-server.a. Pinned tag
# so the build is reproducible; bump this together with the Android
# CMakeLists.txt `LLAMA_VERSION`.
LLAMA_VERSION="b4120"
LLAMA_SRC_DIR="$BUILD_BASE/llama.cpp"
LLAMA_PATCH_DIR="$PROJECT_DIR/versions/llama_cpp/patches"

echo "========================================="
echo "  Dazzle: iOS Cross-Compilation"
echo "========================================="

# ===== Fetch hnswlib (header-only HNSW for vector search) =====
mkdir -p "$HNSWLIB_DIR"
if [ ! -f "$HNSWLIB_DIR/hnswlib/hnswlib.h" ]; then
    git clone --depth 1 --branch v0.8.0 https://github.com/nmslib/hnswlib.git "$HNSWLIB_DIR" 2>/dev/null
fi

# R12.b — inject `searchKnnEf(data, k, ef)` overload into hnswlib so
# parallel queries can pass ef per call without mutating the shared
# `ef_` member via setEf(). Mirrors the same patch applied by
# sdk/android/src/main/cpp/CMakeLists.txt; idempotent.
if ! grep -q "searchKnnEf(" "$HNSWLIB_DIR/hnswlib/hnswalg.h"; then
    perl -0777 -i -pe '
        my $anchor   = "    std::vector<std::pair<dist_t, labeltype >>\n    searchStopConditionClosest(";
        my $overload = "    // dazzle R12.b — per-call ef overload. Upstream searchKnn reads the\n    // shared member `ef_`, forcing callers to serialize around setEf(). This\n    // variant takes ef as an argument so concurrent queries on the same\n    // index can use different ef values without any shared mutation.\n    std::priority_queue<std::pair<dist_t, labeltype >>\n    searchKnnEf(const void *query_data, size_t k, size_t ef, BaseFilterFunctor* isIdAllowed = nullptr) const {\n        std::priority_queue<std::pair<dist_t, labeltype >> result;\n        if (cur_element_count == 0) return result;\n        tableint currObj = enterpoint_node_;\n        dist_t curdist = fstdistfunc_(query_data, getDataByInternalId(enterpoint_node_), dist_func_param_);\n        for (int level = maxlevel_; level > 0; level--) {\n            bool changed = true;\n            while (changed) {\n                changed = false;\n                unsigned int *data = (unsigned int *) get_linklist(currObj, level);\n                int size = getListCount(data);\n                metric_hops++;\n                metric_distance_computations += size;\n                tableint *datal = (tableint *) (data + 1);\n                for (int i = 0; i < size; i++) {\n                    tableint cand = datal[i];\n                    if (cand < 0 || cand > max_elements_) throw std::runtime_error(\"cand error\");\n                    dist_t d = fstdistfunc_(query_data, getDataByInternalId(cand), dist_func_param_);\n                    if (d < curdist) { curdist = d; currObj = cand; changed = true; }\n                }\n            }\n        }\n        std::priority_queue<std::pair<dist_t, tableint>, std::vector<std::pair<dist_t, tableint>>, CompareByFirst> top_candidates;\n        bool bare_bone_search = !num_deleted_ && !isIdAllowed;\n        if (bare_bone_search) {\n            top_candidates = searchBaseLayerST<true>(currObj, query_data, std::max(ef, k), isIdAllowed);\n        } else {\n            top_candidates = searchBaseLayerST<false>(currObj, query_data, std::max(ef, k), isIdAllowed);\n        }\n        while (top_candidates.size() > k) top_candidates.pop();\n        while (top_candidates.size() > 0) {\n            std::pair<dist_t, tableint> rez = top_candidates.top();\n            result.push(std::pair<dist_t, labeltype>(rez.first, getExternalLabel(rez.second)));\n            top_candidates.pop();\n        }\n        return result;\n    }\n\n\n    std::vector<std::pair<dist_t, labeltype >>\n    searchStopConditionClosest(";
        s/\Q$anchor\E/$overload/;
    ' "$HNSWLIB_DIR/hnswlib/hnswalg.h" || fail "failed to inject searchKnnEf into hnswalg.h"
    grep -q "searchKnnEf(" "$HNSWLIB_DIR/hnswlib/hnswalg.h" \
        || fail "searchKnnEf injection did not land in hnswalg.h"
    info "injected searchKnnEf into hnswlib/hnswalg.h"
fi

# ===== Fetch llama.cpp (pinned tag, patched in-tree) =====
mkdir -p "$LLAMA_SRC_DIR"
if [ ! -f "$LLAMA_SRC_DIR/CMakeLists.txt" ]; then
    git clone --depth 1 --branch "$LLAMA_VERSION" \
        https://github.com/ggerganov/llama.cpp.git "$LLAMA_SRC_DIR" 2>/dev/null \
        || fail "failed to clone llama.cpp @ $LLAMA_VERSION"
    info "fetched llama.cpp @ $LLAMA_VERSION"

    # Apply any local patches (workarounds, bug fixes) — matches the
    # versions/v9/patches pattern used for Valkey. Missing dir = no
    # patches this release.
    if [ -d "$LLAMA_PATCH_DIR" ]; then
        for patch in "$LLAMA_PATCH_DIR"/*.patch; do
            [ -e "$patch" ] || continue
            ( cd "$LLAMA_SRC_DIR" && git apply --whitespace=nowarn "$patch" ) \
                || fail "failed to apply $(basename "$patch")"
            info "applied llama.cpp patch $(basename "$patch")"
        done
    fi
fi

# ===== Patches =====
apply_patches() {
    local DIR="$1"
    local have_02_03=0 have_04=0 have_05=0
    grep -q "mach_task_self_"          "$DIR/src/server.c" 2>/dev/null && have_02_03=1
    grep -q "dazzle_tls_current_client" "$DIR/src/server.h" 2>/dev/null && have_04=1
    grep -q "Dazzle in-process mode"    "$DIR/src/server.c" 2>/dev/null && have_05=1

    if [ "$have_02_03" = "0" ]; then
        for patch in "$PATCH_DIR/02_ios.patch" "$PATCH_DIR/03_server_hook.patch"; do
            [ -f "$patch" ] || fail "missing patch: $patch"
            ( cd "$DIR" && git apply --whitespace=nowarn "$patch" ) \
                || fail "failed to apply $(basename "$patch")"
            info "applied $(basename "$patch")"
        done
    fi
    if [ "$have_04" = "0" ]; then
        [ -f "$PATCH_DIR/04_threading.patch" ] || fail "missing patch: 04_threading.patch"
        ( cd "$DIR" && git apply --whitespace=nowarn "$PATCH_DIR/04_threading.patch" ) \
            || fail "failed to apply 04_threading.patch"
        info "applied 04_threading.patch"
    fi
    if [ "$have_05" = "0" ]; then
        [ -f "$PATCH_DIR/05_no_listener.patch" ] || fail "missing patch: 05_no_listener.patch"
        ( cd "$DIR" && git apply --whitespace=nowarn "$PATCH_DIR/05_no_listener.patch" ) \
            || fail "failed to apply 05_no_listener.patch"
        info "applied 05_no_listener.patch"
    fi

    # release.h holds Valkey's INFO string and is generated from git.
    (cd "$DIR/src" && sh mkreleasehdr.sh 2>/dev/null || true)
}

# ===== Build for one platform =====
build_platform() {
    local PLATFORM="$1"   # iphoneos or iphonesimulator
    local TARGET="$2"     # arm64-apple-ios15.0 or arm64-apple-ios15.0-simulator
    local BUILD_DIR="$BUILD_BASE/$PLATFORM"

    echo ""
    echo "--- Building for $PLATFORM ($TARGET) ---"

    # Fresh clone
    rm -rf "$BUILD_DIR"
    git clone --depth 1 --branch "$VALKEY_VERSION" https://github.com/valkey-io/valkey.git "$BUILD_DIR" 2>/dev/null
    apply_patches "$BUILD_DIR"

    # Patch module.c to recognize `@static:<name>` as a sentinel for modules
    # statically linked into the host binary. When seen:
    #   - `handle` is set to RTLD_DEFAULT so dlsym searches all loaded images
    #   - the OnLoad lookup name becomes `ValkeyModule_OnLoad_<name>` so
    #     multiple static modules can coexist in one process without
    #     colliding on a single `ValkeyModule_OnLoad` symbol.
    # Same shape as sdk/android/src/main/cpp/apply_patches.sh.
    perl -0777 -i -pe '
        s{    handle = dlopen\(path, dlopen_flags\);\n    if \(handle == NULL\) \{\n        serverLog\(LL_WARNING, "Module %s failed to load: %s", path, dlerror\(\)\);\n        return C_ERR;\n    \}\n\n    const char \*onLoadNames\[\] = \{"ValkeyModule_OnLoad", "RedisModule_OnLoad"\};}
         {    /* DAZZLE_STATIC_MODULE: @static:<name> is linked into the host binary.\n     * Resolve via RTLD_DEFAULT and a per-module ValkeyModule_OnLoad_<name>\n     * symbol so multiple static modules can coexist in one process. */\n    char _dazzle_onload_name[128] = \{0\};\n    if (path \&\& strncmp(path, "\@static:", 8) == 0) \{\n        handle = RTLD_DEFAULT;\n        snprintf(_dazzle_onload_name, sizeof(_dazzle_onload_name),\n                 "ValkeyModule_OnLoad_%s", path + 8);\n    \} else \{\n        handle = dlopen(path, dlopen_flags);\n        if (handle == NULL) \{\n            serverLog(LL_WARNING, "Module %s failed to load: %s", path, dlerror());\n            return C_ERR;\n        \}\n    \}\n\n    const char *onLoadNames[] = \{\n        _dazzle_onload_name[0] ? _dazzle_onload_name : "ValkeyModule_OnLoad",\n        "RedisModule_OnLoad",\n    \};}
    ' "$BUILD_DIR/src/module.c" || fail "failed to patch module.c for @static modules"
    grep -q "DAZZLE_STATIC_MODULE" "$BUILD_DIR/src/module.c" \
        || fail "static-module patch did not land in module.c"
    info "patched module.c for static module loading"

    local SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
    local CC="$(xcrun --sdk "$PLATFORM" --find clang)"
    local AR="$(xcrun --sdk "$PLATFORM" --find ar)"
    local RANLIB="$(xcrun --sdk "$PLATFORM" --find ranlib)"
    local FLAGS="-target $TARGET -isysroot $SDK -Wno-undef -DVALKEY_IOS=1 -fdebug-prefix-map=$BUILD_DIR=$PROJECT_DIR"
    local NPROC=$(sysctl -n hw.ncpu)

    cd "$BUILD_DIR"
    # Build will fail at link stage (main renamed to valkey_main) — that's expected.
    # We only need the .o files for the static library, not the valkey-server binary.
    # Use -k (keep going) so all .o files compile even when linking fails.
    make -C src -j"$NPROC" -k \
        CC="$CC $FLAGS" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        MALLOC=libc USE_JEMALLOC=no USE_SYSTEMD=no BUILD_TLS=no \
        OPTIMIZATION="-O2" \
        CFLAGS="-Wno-undef -DVALKEY_IOS=1" || true

    # Create static library by merging server .o files with dependency .a files.
    # Strategy: collect server .o names first, then extract only NON-CONFLICTING
    # .o files from deps. This ensures the server's implementations always win
    # when both server and deps define the same function (e.g., adlist, crc16, sds).
    local MERGE_DIR="$BUILD_DIR/merge_objs"
    mkdir -p "$MERGE_DIR"

    # Step 1: Copy server .o files (these always take priority)
    for f in src/*.o; do
        case "$(basename "$f")" in
            valkey-cli.o|valkey-benchmark.o|cli_commands.o|cli_common.o) continue ;;
            *) cp "$f" "$MERGE_DIR/" ;;
        esac
    done
    cp src/trace/*.o "$MERGE_DIR/" 2>/dev/null || true
    cp src/lua/*.o "$MERGE_DIR/" 2>/dev/null || true
    cp src/modules/lua/*.o "$MERGE_DIR/" 2>/dev/null || true

    # Step 2: Extract dep .o files. On name collision, rename with prefix
    # (e.g. hiredis has its own sds.o with hi_sds* funcs needed alongside server's).
    for lib in deps/hiredis/libhiredis.a deps/libvalkey/lib/libvalkey.a deps/hdr_histogram/libhdrhistogram.a deps/fpconv/libfpconv.a deps/lua/src/liblua.a; do
        if [ -f "$lib" ]; then
            local dep_tmp="$BUILD_DIR/dep_tmp_$$"
            local lib_prefix=$(basename "$(dirname "$lib")")
            rm -rf "$dep_tmp" && mkdir -p "$dep_tmp"
            (cd "$dep_tmp" && $AR x "$BUILD_DIR/$lib")
            for dep_obj in "$dep_tmp"/*.o; do
                local base=$(basename "$dep_obj")
                if [ -f "$MERGE_DIR/$base" ]; then
                    cp "$dep_obj" "$MERGE_DIR/${lib_prefix}_${base}"
                else
                    cp "$dep_obj" "$MERGE_DIR/"
                fi
            done
            rm -rf "$dep_tmp"
        fi
    done

    # Compile dazzle_transport.c (lives in core/transport/) with Valkey include
    # paths. The DAZZLE_VECTORSEARCH / DAZZLE_TFI defines pull in the anti-dead-
    # strip references (see the bottom of dazzle_transport.c) so the per-module
    # OnLoad symbols survive the linker's gc pass and are reachable by dlsym
    # at runtime.
    "$CC" $FLAGS -O2 -DVALKEY_IOS=1 -DDAZZLE_VECTORSEARCH=1 -DDAZZLE_TFI=1 \
        -I"$BUILD_DIR/src" \
        -I"$BUILD_DIR/deps/lua/src" \
        -I"$CORE_DIR/transport" \
        -c "$CORE_DIR/transport/dazzle_transport.c" -o "$MERGE_DIR/valkey_direct.o"

    # Plan 02: worker pool for parallel read execution (shadow mode by default).
    "$CC" $FLAGS -O2 -DVALKEY_IOS=1 \
        -I"$BUILD_DIR/src" \
        -I"$BUILD_DIR/deps/lua/src" \
        -I"$CORE_DIR/transport" \
        -c "$CORE_DIR/transport/dazzle_worker_pool.c" -o "$MERGE_DIR/dazzle_worker_pool.o"

    # Fetch simsimd headers (pulled from valkey-search/third_party). simsimd
    # powers the SQ8 + FP16 distance kernels (NEON SDOT / FMLA on fp16
    # lanes). Same FetchContent dance Android runs, without CMake.
    local VS_SRC_DIR="$BUILD_BASE/valkey_search"
    if [ ! -d "$VS_SRC_DIR/third_party/simsimd/include" ]; then
        rm -rf "$VS_SRC_DIR"
        git clone --depth 1 --branch main https://github.com/valkey-io/valkey-search.git "$VS_SRC_DIR" 2>/dev/null
    fi

    # simsimd dynamic-dispatch TU — built as C. Produces simsimd_dot_f32 /
    # simsimd_l2sq_f32 / simsimd_cos_i8 / simsimd_dot_f16 at link time,
    # which valkeysearch_module.cc picks up when DAZZLE_VECTOR_SIMSIMD is
    # defined.
    "$CC" $FLAGS -O3 -fPIC \
        -march=armv8.2-a+fp16+dotprod \
        -I"$VS_SRC_DIR" \
        -c "$PROJECT_DIR/sdk/android/src/main/cpp/simsimd_lib.c" \
        -o "$MERGE_DIR/simsimd_lib.o"
    info "compiled simsimd_lib.c for $PLATFORM"

    # dazzle-search: HNSW vector module. Compiled into libvalkey-server.a so
    # it's loaded via `--loadmodule @static:vectorsearch` — the patched
    # module.c finds ValkeyModule_OnLoad_vectorsearch via
    # dlsym(RTLD_DEFAULT,...). DAZZLE_VECTOR_SIMSIMD activates the SQ8/F16
    # paths; armv8.2-a+fp16+dotprod enables the NEON intrinsics.
    local CXX="$(xcrun --sdk "$PLATFORM" --find clang++)"
    "$CXX" $FLAGS -std=c++17 -O3 -fPIC \
        -DVALKEY_IOS=1 -D__IOS__ \
        -DDAZZLE_VECTOR_SIMSIMD=1 \
        -march=armv8.2-a+fp16+dotprod \
        -Wno-unknown-pragmas -Wno-unused-variable \
        -I"$BUILD_DIR/src" \
        -I"$HNSWLIB_DIR/hnswlib" \
        -I"$VS_SRC_DIR/third_party/simsimd/include" \
        -c "$PROJECT_DIR/sdk/android/src/main/cpp/valkeysearch_module.cc" \
        -o "$MERGE_DIR/valkeysearch_module.o"
    info "compiled valkeysearch_module.cc for $PLATFORM"

    # dazzle-tfi: Temporal Fault Intelligence module. Same static-link path
    # as valkey-search — bundled into the archive, found via
    # `--loadmodule @static:tfi` + ValkeyModule_OnLoad_tfi.
    "$CC" $FLAGS -std=gnu11 -O2 -fPIC \
        -DVALKEY_IOS=1 -D__IOS__ \
        -I"$BUILD_DIR/src" \
        -c "$PROJECT_DIR/sdk/android/src/main/cpp/tfi_module.c" \
        -o "$MERGE_DIR/tfi_module.o"
    info "compiled tfi_module.c for $PLATFORM"

    # ===== llama.cpp — cross-compile with CMake =====
    # Builds libllama.a + libggml*.a into a per-platform out dir,
    # then we extract the .o files and merge them into
    # libvalkey-server.a so the xcframework stays single-archive.
    local LLAMA_BUILD="$BUILD_DIR/llama_build"
    rm -rf "$LLAMA_BUILD"
    local CMAKE_SYSTEM_NAME="iOS"
    # Simulator targets still report iOS but with the iphonesimulator
    # sysroot — CMake handles that via CMAKE_OSX_SYSROOT.
    local DEVICE_FLAG="OS"
    if [ "$PLATFORM" = "iphonesimulator" ]; then
        DEVICE_FLAG="SIMULATOR"
    fi

    cmake -S "$LLAMA_SRC_DIR" -B "$LLAMA_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
        -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -fPIC" \
        -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -fPIC" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DLLAMA_CURL=OFF \
        -DGGML_METAL=OFF \
        -DGGML_BLAS=OFF \
        -DGGML_OPENMP=OFF \
        -DGGML_ACCELERATE=OFF \
        -DGGML_LLAMAFILE=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_CPU=ON \
        -DCMAKE_SKIP_INSTALL_RULES=ON \
        > "$BUILD_DIR/cmake_llama_${PLATFORM}.log" 2>&1 \
        || { cat "$BUILD_DIR/cmake_llama_${PLATFORM}.log"; fail "llama.cpp cmake config failed"; }

    cmake --build "$LLAMA_BUILD" --config Release \
        --target llama ggml ggml-base ggml-cpu \
        -- -j"$NPROC" \
        > "$BUILD_DIR/build_llama_${PLATFORM}.log" 2>&1 \
        || { tail -40 "$BUILD_DIR/build_llama_${PLATFORM}.log"; fail "llama.cpp build failed"; }
    info "compiled llama.cpp $LLAMA_VERSION for $PLATFORM"

    # Extract .o files from every llama.cpp .a into the merge dir. All
    # object names are prefixed with `llama_` so they don't collide
    # with server-side objects of the same name (e.g. util.o).
    local LLAMA_TMP="$BUILD_DIR/llama_tmp"
    rm -rf "$LLAMA_TMP" && mkdir -p "$LLAMA_TMP"
    for lib in $(find "$LLAMA_BUILD" -name "*.a"); do
        local lib_prefix="llama_$(basename "${lib%.a}")"
        local this_tmp="$LLAMA_TMP/$lib_prefix"
        mkdir -p "$this_tmp"
        (cd "$this_tmp" && $AR x "$lib")
        for obj in "$this_tmp"/*.o; do
            [ -e "$obj" ] || continue
            cp "$obj" "$MERGE_DIR/${lib_prefix}_$(basename "$obj")"
        done
    done
    info "merged llama.cpp objects into libvalkey-server.a staging"

    # Build dazzle_llama.c (plain-C wrapper over the llama.cpp C API).
    # This is what Swift and Kotlin call — the lib itself never crosses
    # the language boundary directly.
    "$CXX" $FLAGS -std=c++17 -O2 -fPIC \
        -DVALKEY_IOS=1 -D__IOS__ \
        -I"$LLAMA_SRC_DIR/include" \
        -I"$LLAMA_SRC_DIR/ggml/include" \
        -c "$CORE_DIR/platform/dazzle_llama.cpp" \
        -o "$MERGE_DIR/dazzle_llama.o"
    info "compiled dazzle_llama.cpp for $PLATFORM"

    $AR rcs "$BUILD_DIR/libvalkey-server.a" "$MERGE_DIR"/*.o
    info "$PLATFORM: libvalkey-server.a ($(du -h "$BUILD_DIR/libvalkey-server.a" | awk '{print $1}'))"
}

# ===== Build both platforms =====
build_platform "iphoneos" "arm64-apple-ios${MIN_IOS}"
build_platform "iphonesimulator" "arm64-apple-ios${MIN_IOS}-simulator"

# ===== Copy C wrapper =====
echo ""
echo "--- Creating XCFramework ---"

# Headers directory
HEADERS_DIR="$BUILD_BASE/headers"
mkdir -p "$HEADERS_DIR"
cp "$CORE_DIR/platform/dazzle_ios.h" "$HEADERS_DIR/" 2>/dev/null || \
cat > "$HEADERS_DIR/dazzle_ios.h" << 'HEADER_EOF'
#ifndef VALKEY_IOS_H
#define VALKEY_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

int dazzle_ios_start(const char *data_dir, int port, const char *max_memory);
void dazzle_ios_stop(int port);
int dazzle_ios_is_running(void);

#ifdef __cplusplus
}
#endif

#endif
HEADER_EOF

# Plain-C vector-search surface (SQ8 / F16 / addDirect / searchDirect
# helpers live in valkeysearch_module.cc and are re-exported so Swift
# can call them via `import DazzleC`).
cp "$CORE_DIR/platform/dazzle_vs.h" "$HEADERS_DIR/" || fail "missing dazzle_vs.h"

# Plain-C llama.cpp surface — embedded llama.cpp compiled into
# libvalkey-server.a; Swift side calls dazzle_llama_* from DazzleC.
cp "$CORE_DIR/platform/dazzle_llama.h" "$HEADERS_DIR/" || fail "missing dazzle_llama.h"

# Module map for Swift
cat > "$HEADERS_DIR/module.modulemap" << 'MODMAP_EOF'
module DazzleC {
    header "dazzle_ios.h"
    header "dazzle_vs.h"
    header "dazzle_llama.h"
    export *
}
MODMAP_EOF

# Create xcframework
rm -rf "$OUTPUT_DIR/Dazzle.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD_BASE/iphoneos/libvalkey-server.a" \
    -headers "$HEADERS_DIR" \
    -library "$BUILD_BASE/iphonesimulator/libvalkey-server.a" \
    -headers "$HEADERS_DIR" \
    -output "$OUTPUT_DIR/Dazzle.xcframework"

info "XCFramework created: $OUTPUT_DIR/Dazzle.xcframework"

# ===== Cleanup =====
rm -rf "$BUILD_BASE"

echo ""
echo "========================================="
info "iOS build complete!"
echo ""
echo "  Add to your Xcode project:"
echo "    1. Drag Dazzle.xcframework into your project"
echo "    2. Set 'Embed & Sign' in Frameworks settings"
echo "    3. import DazzleC in Swift files"
echo "========================================="
