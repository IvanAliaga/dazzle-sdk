cmake_minimum_required(VERSION 3.22)
project(dazzle_wasm CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# Same hnswlib version the iOS / Android builds consume — keeps behaviour
# (search ordering, memory layout, snapshot binary format) identical so an
# index built natively can be inspected, debugged or migrated alongside web
# clients.
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

# NOTE: the iOS/Android builds patch hnswlib with a `searchKnnEf` overload
# so concurrent queries can use different ef values without serialising
# around `setEf()`.  WASM in the browser is single-threaded by default
# (multi-threading needs SharedArrayBuffer + COOP/COEP headers, which we
# don't enable in the MVP), so we skip that patch here and call the
# unpatched `searchKnn` after a transient `setEf`.

# WASM target.  Emscripten's emcmake invocation sets the toolchain.
add_executable(dazzle src/dazzle_wasm.cpp)

target_include_directories(dazzle PRIVATE ${hnswlib_src_SOURCE_DIR})

target_compile_options(dazzle PRIVATE
    -O3
    # Exceptions stay ON because hnswlib uses `throw std::runtime_error` for
    # capacity / level overflow errors. Native EH adds ~80 KB to the wasm
    # vs -fno-exceptions but keeps the upstream library compatible.
    -Wall -Wextra
)

# Emscripten-specific link flags.  Each on its own line for readability.
target_link_options(dazzle PRIVATE
    -O3
    -fexceptions                        # link-time match; required by hnswlib
    -sMODULARIZE=1
    -sEXPORT_ES6=1
    -sEXPORT_NAME=dazzleModule
    -sENVIRONMENT=web
    -sALLOW_MEMORY_GROWTH=1
    -sINITIAL_MEMORY=33554432           # 32 MB starting heap; grows on demand
    -sMAXIMUM_MEMORY=2147483648         # 2 GB cap
    # FILESYSTEM stays ON (default) so hnswlib v0.8.0 can save/load via
    # in-memory paths under /tmp.  ~50 KB of glue cost vs FILESYSTEM=0,
    # but lets us reuse upstream save/load instead of forking the lib.
    -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString,stringToUTF8,lengthBytesUTF8,HEAPU8,HEAPF32
    -sEXPORTED_FUNCTIONS=_malloc,_free,_dazzle_hset,_dazzle_hget,_dazzle_hdel,_dazzle_hexists,_dazzle_hgetall,_dazzle_del,_dazzle_vs_create,_dazzle_vs_add,_dazzle_vs_search,_dazzle_vs_search_ids,_dazzle_vs_drop,_dazzle_save_snapshot,_dazzle_load_snapshot,_dazzle_snapshot_release,_dazzle_version,_dazzle_clear
)

set_target_properties(dazzle PROPERTIES
    OUTPUT_NAME "dazzle"
    SUFFIX ".js"
)

# Side-effect outputs: emcc emits dazzle.js + dazzle.wasm next to the target.
