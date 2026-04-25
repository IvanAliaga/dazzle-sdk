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
add_subdirectory(${llama_src_SOURCE_DIR} llama_build EXCLUDE_FROM_ALL)

# ===== Main library: dazzle.so ============================================
# Everything — Valkey server, JNI bridge, transport layer, and ALL shipped
# modules — compiles into a single libdazzle.so. Modules are loaded via
# --loadmodule @static:<name> which the patched module.c resolves to
# RTLD_DEFAULT + ValkeyModule_OnLoad_<name>. This keeps the consumer APK to
# a single native library, mirrors the iOS xcframework layout, and sidesteps
# Android's extractNativeLibs packaging quirk for per-module .so files.
add_library(dazzle SHARED
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

target_include_directories(dazzle PRIVATE
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

target_compile_options(dazzle PRIVATE
    -O2
    -D__ANDROID__
    -D_GNU_SOURCE
    -DUSE_EPOLL
    # Per-module gating macros: flip the anti-dead-strip block in
    # core/transport/dazzle_transport.c (iOS-only — Android uses -Wl,-u)
    # and satisfy #if defined(DAZZLE_VECTOR_SIMSIMD) inside
    # valkeysearch_module.cc / simsimd_lib.c (arm64 NEON kernels).
    -DDAZZLE_VECTORSEARCH=1
    -DDAZZLE_TFI=1
    -DDAZZLE_VECTOR_SIMSIMD=1
    -Wall
    -Wno-unused-function
    -Wno-unused-variable
    -Wno-deprecated-declarations
    -Wno-unknown-pragmas
    # Patch 04 — TLS model decision deferred (see docs/plans/02 Addendum §TlsMode).
    # Keeping emulated TLS (the NDK default for dlopen'd .so) because the native
    # model (-fno-emulated-tls -ftls-model=global-dynamic) crashed with SIGSEGV
    # at dazzle_tls_current_client-dependent paths on arm64 bionic when the lib
    # is System.loadLibrary'd.  Exposing TlsMode.{Emulated,Native,Auto} as an
    # SDK config is tracked for paper 2.
)

# Per-language flags — Valkey & co. need gnu11 C; valkeysearch_module.cc needs
# C++17 with hnswlib's arm64 NEON features. simsimd_lib.c stays C but needs
# the same target arch to unlock its runtime dispatcher.
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/valkeysearch_module.cc
    PROPERTIES COMPILE_FLAGS "-std=c++17 -O3 -fPIC -fno-plt -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -march=armv8.2-a+fp16+dotprod -mcpu=generic")
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/simsimd_lib.c
    PROPERTIES COMPILE_FLAGS "-O3 -fPIC -march=armv8.2-a+fp16+dotprod -mcpu=generic")
# dazzle_llama.cpp wraps llama.cpp's C++ API — C++17 like the search module.
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/platform/dazzle_llama.cpp
    PROPERTIES COMPILE_FLAGS "-std=c++17 -O2 -fPIC")
foreach(_src ${VALKEY_SERVER_SOURCES}
        ${CMAKE_CURRENT_SOURCE_DIR}/dazzle_jni.c
        ${CMAKE_CURRENT_SOURCE_DIR}/dazzle_llama_jni.c
        ${CMAKE_CURRENT_SOURCE_DIR}/tfi_module.c
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/transport/dazzle_transport.c
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/transport/dazzle_worker_pool.c)
    set_source_files_properties(${_src} PROPERTIES COMPILE_FLAGS "-std=gnu11")
endforeach()

target_link_libraries(dazzle
    libvalkey_dep
    lua_dep
    linenoise_dep
    hdr_histogram_dep
    fpconv_dep
    # llama.cpp inference stack — `llama` depends transitively on
    # ggml, ggml-base and ggml-cpu, but listing them explicitly keeps
    # the link line order stable across CMake versions.
    llama
    ggml
    ggml-base
    ggml-cpu
    m dl log
)

# 16KB page alignment for Android 15+.
# --export-dynamic exposes symbols the patched module.c resolves via
# dlsym(RTLD_DEFAULT, "ValkeyModule_OnLoad_<name>"). Undefined refs (-u)
# pin the per-module OnLoad symbols so --gc-sections can't drop them:
# the linker has no visible caller of those functions inside libdazzle.so.
target_link_options(dazzle PRIVATE
    -Wl,-z,max-page-size=16384
    -Wl,-z,separate-loadable-segments
    -Wl,--export-dynamic
    -Wl,-u,ValkeyModule_OnLoad_vectorsearch
    -Wl,-u,ValkeyModule_OnLoad_tfi
    -Wl,-u,dazzle_vectorsearch_onload_ref
    -Wl,-u,dazzle_tfi_onload_ref
)
