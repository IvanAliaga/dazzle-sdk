cmake_minimum_required(VERSION 3.13)
set(PROJECT_NAME "dazzle_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

# This file is shipped as part of the Flutter Linux Desktop plugin
# scaffold.  We don't compile any Flutter wrapper code — the entire
# bridge runs through dart:ffi against pre-built libdazzle_lite.so.
# All we need is to make sure the binary lands next to the runner.
set(dazzle_flutter_bundled_libraries
    "${CMAKE_CURRENT_SOURCE_DIR}/native/libdazzle_lite.so"
    PARENT_SCOPE
)
