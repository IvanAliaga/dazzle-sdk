cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "dazzle_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

# Pre-built dazzle_lite.dll is staged into native/ by the WASM/native
# build step in CI.  We just hand it to the Flutter Windows runner so
# it ends up alongside the .exe.
set(dazzle_flutter_bundled_libraries
    "${CMAKE_CURRENT_SOURCE_DIR}/native/dazzle_lite.dll"
    PARENT_SCOPE
)
