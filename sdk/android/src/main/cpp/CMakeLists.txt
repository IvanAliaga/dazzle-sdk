cmake_minimum_required(VERSION 3.22)
project(dazzle C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# ===== Fetch Valkey source (download only, skip its CMake) =====
FetchContent_Declare(
    valkey_src
    GIT_REPOSITORY https://github.com/valkey-io/valkey.git
    GIT_SHALLOW TRUE
    GIT_TAG 9.0.3
)
FetchContent_GetProperties(valkey_src)
if(NOT valkey_src_POPULATED)
    FetchContent_Populate(valkey_src)
endif()

set(VALKEY_SRC ${valkey_src_SOURCE_DIR}/src)
set(VALKEY_DEPS ${valkey_src_SOURCE_DIR}/deps)

# ===== Apply Android patches =====
set(PATCH_SCRIPT ${CMAKE_CURRENT_SOURCE_DIR}/apply_patches.sh)
execute_process(
    COMMAND bash ${PATCH_SCRIPT} ${valkey_src_SOURCE_DIR}
    RESULT_VARIABLE PATCH_RESULT
)
if(NOT PATCH_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to apply Android patches")
endif()

# ===== Generate release.h =====
execute_process(
    COMMAND bash -c "cd ${VALKEY_SRC} && sh mkreleasehdr.sh"
    RESULT_VARIABLE RELEASE_RESULT
)

# ===== Valkey server source files =====
set(VALKEY_SERVER_SOURCES
    ${VALKEY_SRC}/acl.c
    ${VALKEY_SRC}/adlist.c
    ${VALKEY_SRC}/ae.c
    ${VALKEY_SRC}/allocator_defrag.c
    ${VALKEY_SRC}/anet.c
    ${VALKEY_SRC}/aof.c
    ${VALKEY_SRC}/bio.c
    ${VALKEY_SRC}/bitops.c
    ${VALKEY_SRC}/blocked.c
    ${VALKEY_SRC}/call_reply.c
    ${VALKEY_SRC}/childinfo.c
    ${VALKEY_SRC}/cluster.c
    ${VALKEY_SRC}/cluster_legacy.c
    ${VALKEY_SRC}/cluster_migrateslots.c
    ${VALKEY_SRC}/cluster_slot_stats.c
    ${VALKEY_SRC}/commandlog.c
    ${VALKEY_SRC}/commands.c
    ${VALKEY_SRC}/config.c
    ${VALKEY_SRC}/connection.c
    ${VALKEY_SRC}/crc16.c
    ${VALKEY_SRC}/crc64.c
    ${VALKEY_SRC}/crccombine.c
    ${VALKEY_SRC}/crcspeed.c
    ${VALKEY_SRC}/db.c
    ${VALKEY_SRC}/debug.c
    ${VALKEY_SRC}/defrag.c
    ${VALKEY_SRC}/dict.c
    ${VALKEY_SRC}/endianconv.c
    ${VALKEY_SRC}/entry.c
    ${VALKEY_SRC}/eval.c
    ${VALKEY_SRC}/evict.c
    ${VALKEY_SRC}/expire.c
    ${VALKEY_SRC}/functions.c
    ${VALKEY_SRC}/geo.c
    ${VALKEY_SRC}/geohash.c
    ${VALKEY_SRC}/geohash_helper.c
    ${VALKEY_SRC}/hashtable.c
    ${VALKEY_SRC}/hyperloglog.c
    ${VALKEY_SRC}/intset.c
    ${VALKEY_SRC}/io_threads.c
    ${VALKEY_SRC}/kvstore.c
    ${VALKEY_SRC}/latency.c
    ${VALKEY_SRC}/lazyfree.c
    ${VALKEY_SRC}/listpack.c
    ${VALKEY_SRC}/localtime.c
    ${VALKEY_SRC}/logreqres.c
    ${VALKEY_SRC}/lolwut.c
    ${VALKEY_SRC}/lolwut5.c
    ${VALKEY_SRC}/lolwut6.c
    ${VALKEY_SRC}/lolwut9.c
    ${VALKEY_SRC}/lzf_c.c
    ${VALKEY_SRC}/lzf_d.c
    ${VALKEY_SRC}/memory_prefetch.c
    ${VALKEY_SRC}/memtest.c
    ${VALKEY_SRC}/module.c
    ${VALKEY_SRC}/monotonic.c
    ${VALKEY_SRC}/mt19937-64.c
    ${VALKEY_SRC}/multi.c
    ${VALKEY_SRC}/networking.c
    ${VALKEY_SRC}/notify.c
    ${VALKEY_SRC}/object.c
    ${VALKEY_SRC}/pqsort.c
    ${VALKEY_SRC}/pubsub.c
    ${VALKEY_SRC}/quicklist.c
    ${VALKEY_SRC}/rand.c
    ${VALKEY_SRC}/rax.c
    ${VALKEY_SRC}/rdb.c
    ${VALKEY_SRC}/rdma.c
    ${VALKEY_SRC}/release.c
    ${VALKEY_SRC}/replication.c
    ${VALKEY_SRC}/resp_parser.c
    ${VALKEY_SRC}/rio.c
    ${VALKEY_SRC}/script.c
    ${VALKEY_SRC}/scripting_engine.c
    ${VALKEY_SRC}/sds.c
    ${VALKEY_SRC}/sentinel.c
    ${VALKEY_SRC}/server.c
    ${VALKEY_SRC}/setcpuaffinity.c
    ${VALKEY_SRC}/setproctitle.c
    ${VALKEY_SRC}/sha1.c
    ${VALKEY_SRC}/sha256.c
    ${VALKEY_SRC}/siphash.c
    ${VALKEY_SRC}/socket.c
    ${VALKEY_SRC}/sort.c
    ${VALKEY_SRC}/sparkline.c
    ${VALKEY_SRC}/strl.c
    ${VALKEY_SRC}/syncio.c
    ${VALKEY_SRC}/syscheck.c
    ${VALKEY_SRC}/t_hash.c
    ${VALKEY_SRC}/t_list.c
    ${VALKEY_SRC}/t_set.c
    ${VALKEY_SRC}/t_stream.c
    ${VALKEY_SRC}/t_string.c
    ${VALKEY_SRC}/t_zset.c
    ${VALKEY_SRC}/threads_mngr.c
    ${VALKEY_SRC}/timeout.c
    ${VALKEY_SRC}/tls.c
    ${VALKEY_SRC}/tracking.c
    ${VALKEY_SRC}/unix.c
    ${VALKEY_SRC}/util.c
    ${VALKEY_SRC}/valkey-check-aof.c
    ${VALKEY_SRC}/valkey-check-rdb.c
    ${VALKEY_SRC}/vector.c
    ${VALKEY_SRC}/vset.c
    ${VALKEY_SRC}/ziplist.c
    ${VALKEY_SRC}/zipmap.c
    ${VALKEY_SRC}/zmalloc.c
    ${VALKEY_SRC}/trace/trace.c
    ${VALKEY_SRC}/trace/trace_aof.c
    ${VALKEY_SRC}/trace/trace_cluster.c
    ${VALKEY_SRC}/trace/trace_commands.c
    ${VALKEY_SRC}/trace/trace_db.c
    ${VALKEY_SRC}/trace/trace_rdb.c
    ${VALKEY_SRC}/trace/trace_server.c
    ${VALKEY_SRC}/lua/debug_lua.c
    ${VALKEY_SRC}/lua/engine_lua.c
    ${VALKEY_SRC}/lua/function_lua.c
    ${VALKEY_SRC}/lua/script_lua.c
)

# ===== Dependency libraries =====

# libvalkey (client library used internally)
file(GLOB LIBVALKEY_SOURCES ${VALKEY_DEPS}/libvalkey/src/*.c)
# Exclude TLS and RDMA (not needed, require OpenSSL/RDMA headers)
list(FILTER LIBVALKEY_SOURCES EXCLUDE REGEX "tls\\.c$|rdma\\.c$")
add_library(libvalkey_dep STATIC ${LIBVALKEY_SOURCES})
target_include_directories(libvalkey_dep PUBLIC
    ${VALKEY_DEPS}/libvalkey/include/valkey
    ${VALKEY_DEPS}/libvalkey/include
    ${VALKEY_SRC}
)
target_compile_options(libvalkey_dep PRIVATE -std=c99 -fPIC -O2 -DVALKEY_USE_THREADS)

# Lua
file(GLOB LUA_SOURCES ${VALKEY_DEPS}/lua/src/*.c)
list(FILTER LUA_SOURCES EXCLUDE REGEX "lua\\.c$|luac\\.c$")
add_library(lua_dep STATIC ${LUA_SOURCES})
target_include_directories(lua_dep PUBLIC ${VALKEY_DEPS}/lua/src)
target_compile_options(lua_dep PRIVATE -O2 -fPIC)

# linenoise
add_library(linenoise_dep STATIC ${VALKEY_DEPS}/linenoise/linenoise.c)
target_include_directories(linenoise_dep PUBLIC ${VALKEY_DEPS}/linenoise)

# hdr_histogram
add_library(hdr_histogram_dep STATIC ${VALKEY_DEPS}/hdr_histogram/hdr_histogram.c)
target_include_directories(hdr_histogram_dep PUBLIC ${VALKEY_DEPS}/hdr_histogram ${VALKEY_SRC})
target_compile_definitions(hdr_histogram_dep PRIVATE HDR_MALLOC_INCLUDE="hdr_redis_malloc.h")

# fpconv
add_library(fpconv_dep STATIC ${VALKEY_DEPS}/fpconv/fpconv_dtoa.c)
target_include_directories(fpconv_dep PUBLIC ${VALKEY_DEPS}/fpconv)

# ===== Lua engine (core-integrated in Valkey 9, compiled into dazzle) =====
# In Valkey 8, Lua was a loadable module (modules/lua/). In Valkey 9, it's
# integrated into src/lua/ and linked directly into the server binary.
# The source files are included in VALKEY_SERVER_SOURCES above.

# ===== Vector-search dependencies (header-only hnswlib + simsimd) =========
# Fetched here so HNSWLIB_INCLUDE and valkey_search_src_SOURCE_DIR are
# available to the main libdazzle target below. The module source code
# (valkeysearch_module.cc + simsimd_lib.c) compiles straight into
# libdazzle.so — there is no separate libvalkeysearch.so anymore.

FetchContent_Declare(
    valkey_search_src
    GIT_REPOSITORY https://github.com/valkey-io/valkey-search.git
    GIT_SHALLOW    TRUE
    GIT_TAG        main
)
FetchContent_GetProperties(valkey_search_src)
if(NOT valkey_search_src_POPULATED)
    FetchContent_Populate(valkey_search_src)
endif()

# hnswlib from valkey-search third_party is patched with absl; use the
# original unmodified library from the upstream repo instead.
FetchContent_Declare(
    hnswlib_src
    GIT_REPOSITORY https://github.com/nmslib/hnswlib.git
    GIT_SHALLOW    TRUE
    GIT_TAG        v0.8.0
)
FetchContent_GetProperties(hnswlib_src)
if(NOT hnswlib_src_POPULATED)
    FetchContent_Populate(hnswlib_src)
endif()

# R12.b — inject `searchKnnEf(data, k, ef)` overload into hnswlib so callers
# can pass ef per call instead of mutating the shared `ef_` via setEf(). The
# upstream searchKnn reads from the member, forcing writers to serialize.
# Idempotent: the guard string check skips the injection if already applied.
set(_dazzle_hnswalg "${hnswlib_src_SOURCE_DIR}/hnswlib/hnswalg.h")
file(READ "${_dazzle_hnswalg}" _dazzle_hnsw_src)
string(FIND "${_dazzle_hnsw_src}" "searchKnnEf(" _dazzle_already_patched)
if(_dazzle_already_patched EQUAL -1)
    set(_anchor "    std::vector<std::pair<dist_t, labeltype >>\n    searchStopConditionClosest(")
    set(_overload "    // dazzle R12.b — per-call ef overload. Upstream searchKnn reads the
    // shared member `ef_`, forcing callers to serialize around setEf(). This
    // variant takes ef as an argument so concurrent queries on the same
    // index can use different ef values without any shared mutation.
    std::priority_queue<std::pair<dist_t, labeltype >>
    searchKnnEf(const void *query_data, size_t k, size_t ef, BaseFilterFunctor* isIdAllowed = nullptr) const {
        std::priority_queue<std::pair<dist_t, labeltype >> result;
        if (cur_element_count == 0) return result;
        tableint currObj = enterpoint_node_;
        dist_t curdist = fstdistfunc_(query_data, getDataByInternalId(enterpoint_node_), dist_func_param_);
        for (int level = maxlevel_; level > 0; level--) {
            bool changed = true;
            while (changed) {
                changed = false;
                unsigned int *data = (unsigned int *) get_linklist(currObj, level);
                int size = getListCount(data);
                metric_hops++;
                metric_distance_computations += size;
                tableint *datal = (tableint *) (data + 1);
                for (int i = 0; i < size; i++) {
                    tableint cand = datal[i];
                    if (cand < 0 || cand > max_elements_) throw std::runtime_error(\"cand error\");
                    dist_t d = fstdistfunc_(query_data, getDataByInternalId(cand), dist_func_param_);
                    if (d < curdist) { curdist = d; currObj = cand; changed = true; }
                }
            }
        }
        std::priority_queue<std::pair<dist_t, tableint>, std::vector<std::pair<dist_t, tableint>>, CompareByFirst> top_candidates;
        bool bare_bone_search = !num_deleted_ && !isIdAllowed;
        if (bare_bone_search) {
            top_candidates = searchBaseLayerST<true>(currObj, query_data, std::max(ef, k), isIdAllowed);
        } else {
            top_candidates = searchBaseLayerST<false>(currObj, query_data, std::max(ef, k), isIdAllowed);
        }
        while (top_candidates.size() > k) top_candidates.pop();
        while (top_candidates.size() > 0) {
            std::pair<dist_t, tableint> rez = top_candidates.top();
            result.push(std::pair<dist_t, labeltype>(rez.first, getExternalLabel(rez.second)));
            top_candidates.pop();
        }
        return result;
    }


    std::vector<std::pair<dist_t, labeltype >>
    searchStopConditionClosest(")
    string(REPLACE "${_anchor}" "${_overload}" _dazzle_hnsw_src "${_dazzle_hnsw_src}")
    file(WRITE "${_dazzle_hnswalg}" "${_dazzle_hnsw_src}")
    message(STATUS "dazzle: injected searchKnnEf into hnswlib/hnswalg.h")
endif()

set(HNSWLIB_INCLUDE ${hnswlib_src_SOURCE_DIR}/hnswlib)

# ===== llama.cpp — embedded on-device inference =============================
# Shipped as part of libdazzle.so so consumers get LlamaCppClient without
# pulling a second native library. Pinned tag; local patches (future audio
# workaround, etc.) live under versions/llama_cpp/patches/ and are applied
# on first populate — same pattern versions/v9/patches/ uses for Valkey.

set(LLAMA_VERSION b4120)   # keep in sync with sdk/ios/build.sh

FetchContent_Declare(
    llama_src
    GIT_REPOSITORY https://github.com/ggerganov/llama.cpp.git
    GIT_SHALLOW    TRUE
    GIT_TAG        ${LLAMA_VERSION}
)
FetchContent_GetProperties(llama_src)
if(NOT llama_src_POPULATED)
    FetchContent_Populate(llama_src)
    # Apply llama.cpp patches — empty is fine, glob matches nothing.
    file(GLOB _dazzle_llama_patches
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../versions/llama_cpp/patches/*.patch")
    foreach(_p ${_dazzle_llama_patches})
        execute_process(
            COMMAND git apply --whitespace=nowarn ${_p}
            WORKING_DIRECTORY ${llama_src_SOURCE_DIR}
            RESULT_VARIABLE _rc)
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "llama.cpp patch failed: ${_p}")
        endif()
        message(STATUS "applied llama.cpp patch ${_p}")
    endforeach()
endif()

# Compile llama.cpp as a subdirectory — produces targets `llama`, `ggml`,
# `ggml-base`, `ggml-cpu`. Every example / test / server / CURL dep is
# disabled; we only want the inference core.
set(LLAMA_BUILD_COMMON     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER     OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL             OFF CACHE BOOL "" FORCE)
set(GGML_METAL             OFF CACHE BOOL "" FORCE)
set(GGML_BLAS              OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE)
set(GGML_ACCELERATE        OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE         OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)
set(GGML_CPU               ON  CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
# llama.cpp installs headers / exports by default; we embed it, so skip.
set(LLAMA_SKIP_INSTALL     ON  CACHE BOOL "" FORCE)
# Force ARMv8-A baseline + branch-protection=none down into llama.cpp's
# own targets too. add_subdirectory() means llama / ggml / ggml-base /
# ggml-cpu are SEPARATE targets — `target_compile_options(dazzle ...)`
# does NOT propagate to them. Outline atomics stay enabled (NDK 27
# default): the runtime helpers `__aarch64_have_lse_atomics` flag
# selects between the LSE fast path on chips that support it and the
# safe LDXR/STXR fallback on chips that don't. The MRS-emulation
# handler in dazzle_jni.c keeps that selection working on Kirin 659
# where Linux 4.9 doesn't emulate the underlying ID_AA64* MRS reads.
add_compile_options(-mbranch-protection=none -march=armv8-a -mcpu=generic)
add_subdirectory(${llama_src_SOURCE_DIR} llama_build EXCLUDE_FROM_ALL)

# ===== Main library: dazzle.so + dazzle_v82.so ============================
# Everything — Valkey server, JNI bridge, transport layer, and ALL shipped
# modules — compiles into a single libdazzle*.so. Modules are loaded via
# --loadmodule @static:<name> which the patched module.c resolves to
# RTLD_DEFAULT + ValkeyModule_OnLoad_<name>.
#
# Multi-target dispatch: we now produce TWO variants of the shared
# library and ship both inside the APK. The runtime loader
# (`dev.dazzle.sdk.DazzleNativeLoader`) reads /proc/cpuinfo and picks
# the right one:
#
#   libdazzle.so      `-march=armv8-a -mcpu=generic`
#                     Cross-platform safe baseline. Runs on any
#                     ARMv8.0-A chip — Cortex-A53/A55/A73 — including
#                     Snapdragon 662, Kirin 659, Kirin 710F, MediaTek
#                     Helio G80 small cores. The MRS-emulation handler
#                     in dazzle_jni.c covers Linux 4.9 (Kirin 659).
#
#   libdazzle_v82.so  `-march=armv8.2-a+fp16+dotprod -mcpu=cortex-a78`
#                     Recovers the ~31 % HNSW-search speedup we
#                     measured on the Unisoc T760 reference build
#                     (208 µs vs 306 µs at N = 20 000). Compiles
#                     hnswlib's L2Sqr / InnerProductDistance template
#                     loops with fp16 + dotprod intrinsics that the
#                     baseline target cannot auto-vectorise to. Loaded
#                     only when /proc/cpuinfo advertises both `asimdhp`
#                     and `asimddp` (so the chip can actually execute
#                     the SDOT / fp16 opcodes).
#
# Both variants link against the SAME llama.cpp / ggml subdirectory
# output. ggml-cpu has its own runtime feature dispatcher, so the
# baseline -march on llama is not a perf cost.

# Ordered list of common include directories shared by both variants.
set(_DAZZLE_COMMON_INCLUDES
    ${VALKEY_SRC}
    ${VALKEY_SRC}/lua
    ${VALKEY_DEPS}/libvalkey/include/valkey
    ${VALKEY_DEPS}/libvalkey/include
    ${VALKEY_DEPS}/linenoise
    ${VALKEY_DEPS}/hdr_histogram
    ${VALKEY_DEPS}/fpconv
    ${VALKEY_DEPS}/lua/src
    ${VALKEY_DEPS}/fast_float
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/transport
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/platform
    ${HNSWLIB_INCLUDE}
    ${valkey_search_src_SOURCE_DIR}
    ${valkey_search_src_SOURCE_DIR}/third_party/simsimd/include
    ${llama_src_SOURCE_DIR}/include
    ${llama_src_SOURCE_DIR}/ggml/include
)

# Ordered list of source files shared by both variants.
set(_DAZZLE_COMMON_SOURCES
    ${VALKEY_SERVER_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/dazzle_jni.c
    ${CMAKE_CURRENT_SOURCE_DIR}/valkeysearch_module.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/simsimd_lib.c
    ${CMAKE_CURRENT_SOURCE_DIR}/tfi_module.c
    ${CMAKE_CURRENT_SOURCE_DIR}/dazzle_llama_jni.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/transport/dazzle_transport.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/transport/dazzle_worker_pool.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/platform/dazzle_llama.cpp
)

# Helper that defines one shared-library variant of dazzle.
#
# Args:
#   TARGET     CMake target name (also the resulting libNAME.so basename)
#   MARCH      value passed as -march=<MARCH>
#   MCPU       value passed as -mcpu=<MCPU>
#
# The ${TARGET}-cxx-flags / ${TARGET}-c-flags string variables let us
# attach per-source COMPILE_OPTIONS that follow the variant's -march /
# -mcpu rather than the global ones. CMake's `set_source_files_properties`
# is global per source path, so we route per-target overrides via
# `target_compile_options($<COMPILE_LANGUAGE:...>)` instead.
function(_dazzle_define_variant TARGET MARCH MCPU)
    add_library(${TARGET} SHARED ${_DAZZLE_COMMON_SOURCES})

    target_include_directories(${TARGET} PRIVATE ${_DAZZLE_COMMON_INCLUDES})

    target_compile_options(${TARGET} PRIVATE
        -O2
        -D__ANDROID__
        -D_GNU_SOURCE
        -DUSE_EPOLL
        -DDAZZLE_VECTORSEARCH=1
        -DDAZZLE_TFI=1
        -DDAZZLE_VECTOR_SIMSIMD=1
        -Wall
        -Wno-unused-function
        -Wno-unused-variable
        -Wno-deprecated-declarations
        -Wno-unknown-pragmas
        # PAC/BTI off in user code — Cortex-A73 mis-decodes the HINT
        # opcodes the NDK 27 default emits (see strip_pac_bti.py).
        -mbranch-protection=none
        -march=${MARCH}
        -mcpu=${MCPU}
    )
    # Per-language extras. `set_source_files_properties` is global, so we
    # route per-target overrides through target_compile_options + genex.
    target_compile_options(${TARGET} PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-std=c++17 -O3 -fPIC -fno-plt
            -fvisibility=hidden -fvisibility-inlines-hidden
            -ffunction-sections -fdata-sections>
        $<$<COMPILE_LANGUAGE:C>:-std=gnu11>
    )

    target_link_libraries(${TARGET}
        libvalkey_dep
        lua_dep
        linenoise_dep
        hdr_histogram_dep
        fpconv_dep
        llama ggml ggml-base ggml-cpu
        m dl log
    )

    # 16 KB page alignment + force-export the per-module OnLoad symbols
    # the patched module.c resolves via dlsym(RTLD_DEFAULT, ...).
    target_link_options(${TARGET} PRIVATE
        -Wl,-z,max-page-size=16384
        -Wl,-z,separate-loadable-segments
        -Wl,--export-dynamic
        -Wl,-u,ValkeyModule_OnLoad_vectorsearch
        -Wl,-u,ValkeyModule_OnLoad_tfi
        -Wl,-u,dazzle_vectorsearch_onload_ref
        -Wl,-u,dazzle_tfi_onload_ref
    )

    # Post-link hook: rewrite PAC/BTI HINT opcodes in this variant.
    add_custom_command(TARGET ${TARGET} POST_BUILD
        COMMAND python3 "${CMAKE_CURRENT_SOURCE_DIR}/strip_pac_bti.py" "$<TARGET_FILE:${TARGET}>"
        COMMENT "post-link: stripping PAC/BTI HINT opcodes from $<TARGET_FILE_NAME:${TARGET}>"
        VERBATIM
    )
endfunction()

# Baseline variant: cross-platform safe (every Android arm64 chip).
_dazzle_define_variant(dazzle "armv8-a" "generic")

# Tuned variant: armv8.2-a + fp16 + dotprod, scheduled for Cortex-A78.
# A78 produces the best code for the Unisoc T760 reference device's
# Cortex-A76 big core (only one pipeline generation older). A
# subsequent test with `-mcpu=cortex-a76` showed the same -12 % p50
# regression on Helio G80 (Cortex-A75) as `-mcpu=cortex-a78` — see
# `research/benchmarks/results/multitarget/round3_cortex_a76_test/`
# and §6.3. The conclusion is that the regression is not scheduler-
# model-driven; it lives somewhere in the global codegen the
# ARMv8.2-A + fp16 + dotprod target enables that the Cortex-A75
# microarchitecture executes inefficiently. The current mitigation
# is `force_native_variant=baseline` for chips with known-A75 big
# cores, surfaced through DazzleNativeLoader.
#
# `-mcpu` only controls scheduler/tuning, not the instruction set
# (`-march` does that), so newer chips (A78, A710, X1, etc.) still
# execute every NEON / fp16 / dotprod opcode at hardware speed; they
# just may schedule a marginally narrower instruction window than
# their native model would, which is the right trade-off for a
# cross-chip release binary. Loaded only when /proc/cpuinfo carries
# both asimdhp + asimddp.
_dazzle_define_variant(dazzle_v82 "armv8.2-a+fp16+dotprod" "cortex-a78")
