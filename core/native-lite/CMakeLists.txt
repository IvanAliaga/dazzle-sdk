cmake_minimum_required(VERSION 3.22)
project(dazzle_lite CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

# Same hnswlib version the WASM build (core/web/) uses, so the binary
# index format is identical between web and desktop.
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

# The single TU lives under core/web/ — both build targets compile it.
# This keeps WASM behaviour and native behaviour byte-for-byte aligned.
set(DAZZLE_LITE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/../web/src/dazzle_wasm.cpp)

add_library(dazzle_lite SHARED ${DAZZLE_LITE_SRC})

target_include_directories(dazzle_lite
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${hnswlib_src_SOURCE_DIR}
)

if(MSVC)
    target_compile_options(dazzle_lite PRIVATE /O2 /W4 /D_CRT_SECURE_NO_WARNINGS /EHsc)
else()
    target_compile_options(dazzle_lite PRIVATE -O3 -Wall -Wextra)
endif()

set_target_properties(dazzle_lite PROPERTIES
    OUTPUT_NAME "dazzle_lite"
    VERSION 0.1.0
    SOVERSION 0
)

# On Windows, drop the "lib" prefix so we get dazzle_lite.dll (consistent
# with how Windows native tooling expects it), keep "lib" elsewhere.
if(WIN32)
    set_target_properties(dazzle_lite PROPERTIES PREFIX "")
endif()

install(TARGETS dazzle_lite
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
    ARCHIVE DESTINATION lib
)
install(FILES include/dazzle_lite.h DESTINATION include)
