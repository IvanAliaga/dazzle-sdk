cmake_minimum_required(VERSION 3.22)
project(experiment-native C CXX)

# ──────────────────────────────────────────────────────────────────────────
# LMDB — compiled from source (4 C files from OpenLDAP)
# ──────────────────────────────────────────────────────────────────────────
add_library(lmdb-jni SHARED
    lmdb/mdb.c
    lmdb/midl.c
    lmdb/lmdb_jni.c
)
target_include_directories(lmdb-jni PRIVATE lmdb)
target_link_libraries(lmdb-jni log)
find_package(Threads REQUIRED)
target_link_libraries(lmdb-jni Threads::Threads)

# ──────────────────────────────────────────────────────────────────────────
# RocksDB — fetched from upstream and built from source. Pinned to v9.10.0
# (Jan 2025), the last 9.x release before the 10.x churn that introduced
# breaking C++17 requirements on the public Options API. The bench needs
# RocksDB as the LSM-tree industry-standard reference (§5.2 paper) so the
# build is not optional — if the fetch fails the whole APK build fails,
# which is what we want; previously the `rocksdb-src/ not found` path was
# silent and produced an APK missing librocksdb-jni.so, so the test
# crashed at runtime with UnsatisfiedLinkError instead of failing the
# build.
# ──────────────────────────────────────────────────────────────────────────
set(WITH_TESTS OFF CACHE BOOL "" FORCE)
set(WITH_TOOLS OFF CACHE BOOL "" FORCE)
set(WITH_BENCHMARK_TOOLS OFF CACHE BOOL "" FORCE)
set(WITH_CORE_TOOLS OFF CACHE BOOL "" FORCE)
set(WITH_ALL_TESTS OFF CACHE BOOL "" FORCE)
set(ROCKSDB_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(WITH_GFLAGS OFF CACHE BOOL "" FORCE)
set(WITH_SNAPPY OFF CACHE BOOL "" FORCE)
set(WITH_LZ4 OFF CACHE BOOL "" FORCE)
set(WITH_ZLIB OFF CACHE BOOL "" FORCE)
set(WITH_ZSTD OFF CACHE BOOL "" FORCE)
set(WITH_BZ2 OFF CACHE BOOL "" FORCE)
set(WITH_JEMALLOC OFF CACHE BOOL "" FORCE)
set(PORTABLE ON CACHE BOOL "" FORCE)
set(FAIL_ON_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_RTTI ON CACHE BOOL "" FORCE)
set(WITH_JNI OFF CACHE BOOL "" FORCE)
set(WITH_TRACE_TOOLS OFF CACHE BOOL "" FORCE)
set(WITH_FOLLY_DISTRIBUTED_MUTEX OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
    rocksdb
    GIT_REPOSITORY https://github.com/facebook/rocksdb.git
    GIT_TAG        v9.10.0
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(rocksdb)

add_library(rocksdb-jni SHARED
    rocksdb/rocksdb_jni.cpp
)
target_include_directories(rocksdb-jni PRIVATE
    ${rocksdb_SOURCE_DIR}/include
)
target_link_libraries(rocksdb-jni rocksdb log)

# ──────────────────────────────────────────────────────────────────────────
# sqlite-vec — statically linked SQLite 3.50 + sqlite-vec 0.1.9.
# Exposed to Kotlin via a small JNI shim so we don't need Android's bundled
# SQLite (which doesn't expose sqlite3_enable_load_extension) or requery's
# sqlite-android (which pulls in a whole JDBC-shaped layer).
# ──────────────────────────────────────────────────────────────────────────
add_library(sqlitevec-jni SHARED
    sqlitevec/sqlite3.c
    sqlitevec/sqlite-vec.c
    sqlitevec/sqlitevec_jni.c
)
target_include_directories(sqlitevec-jni PRIVATE sqlitevec)
# SQLite amalgamation compile flags: disable loadable extensions (we statically
# link sqlite-vec instead), disable deprecated APIs, enable threadsafe=1
# (serialized) which is SQLite's recommended default for mobile apps.
target_compile_definitions(sqlitevec-jni PRIVATE
    SQLITE_OMIT_LOAD_EXTENSION=1
    SQLITE_THREADSAFE=1
    SQLITE_DEFAULT_MEMSTATUS=0
    SQLITE_DEFAULT_WAL_SYNCHRONOUS=1
    SQLITE_ENABLE_FTS5=0
    HAVE_USLEEP=1
    # sqlite-vec: avoid the LLM bulk-load helper; we do our own batching.
    SQLITE_VEC_STATIC=1
)
target_link_libraries(sqlitevec-jni log)

# ──────────────────────────────────────────────────────────────────────────
# sqlitevectorai — SQLiteAI's sqlite-vector extension benchmark backend.
# Statically links SQLite with SQLITE_ENABLE_LOAD_EXTENSION and dlopens the
# pre-built libvector.so (shipped via jniLibs/arm64-v8a/libvector.so, extracted
# from their Maven AAR ai.sqlite:vector:0.9.80).
#
# License note: sqlite-vector is Elastic License 2.0 — bench-only, never
# distributed as part of the dazzle SDK. sqlite3.c is source-shared with the
# sqlitevec-jni target above, so duplicating the unit entails a second
# compile with different flags (LOAD_EXTENSION enabled here).
# ──────────────────────────────────────────────────────────────────────────
add_library(sqlitevectorai-jni SHARED
    sqlitevec/sqlite3.c
    sqlitevectorai/sqlitevectorai_jni.c
)
target_include_directories(sqlitevectorai-jni PRIVATE sqlitevec)
target_compile_definitions(sqlitevectorai-jni PRIVATE
    SQLITE_THREADSAFE=1
    SQLITE_DEFAULT_MEMSTATUS=0
    SQLITE_DEFAULT_WAL_SYNCHRONOUS=1
    SQLITE_ENABLE_FTS5=0
    HAVE_USLEEP=1
)
# dlopen/dlsym for sqlite3_load_extension, -ldl is implicit on Android bionic
# but link explicitly for clarity; log for __android_log_print.
target_link_libraries(sqlitevectorai-jni log dl)

# ──────────────────────────────────────────────────────────────────────────
# llama.cpp — GGUF inference for the on-device embedder (E1) and later the
# RAG LLM generator (E2). MIT-licensed, community-owned; chosen over ONNX
# Runtime (Microsoft) + LiteRT (Google) to keep the SDK on a single vendor-
# neutral C runtime + a single model format.
#
# We fetch a pinned tag at configure time and disable all of upstream's
# example/server/test targets — we only need libllama + libggml + libcommon.
#
# Attribution: ATTRIBUTION.md must list llama.cpp (MIT © Georgi Gerganov et
# al.) alongside the existing Valkey notice.
# ──────────────────────────────────────────────────────────────────────────
include(FetchContent)

set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL           OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE       OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE          OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    llama_cpp
    GIT_REPOSITORY https://github.com/ggerganov/llama.cpp.git
    GIT_SHALLOW    TRUE
    # Pin: bump deliberately. b4400 is a stable late-2024 release with Android
    # NDK toolchain fixes and no major API churn from this point forward.
    GIT_TAG        b4400
)
FetchContent_MakeAvailable(llama_cpp)

add_library(llamacpp-jni SHARED
    llamacpp/llamacpp_jni.c
)
# Link only against llama + ggml. `common` is the C++ helper layer (chat
# templates, CLI arg parsing, sampling presets); our JNI shim uses the pure-C
# `llama.h` surface only, so pulling `common` in would force the shim to be
# compiled as C++ and bring in the GPL-adjacent chat-template code we don't
# need.
target_link_libraries(llamacpp-jni PRIVATE llama log)
target_include_directories(llamacpp-jni PRIVATE
    ${llama_cpp_SOURCE_DIR}/include
    ${llama_cpp_SOURCE_DIR}/ggml/include
)
