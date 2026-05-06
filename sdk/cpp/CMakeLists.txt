cmake_minimum_required(VERSION 3.16)
project(dazzle C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Position-independent code is required to link a static .o into a SHARED
# library on Linux. CMake adds it automatically for SHARED targets, but
# we set it explicitly so consumers building dazzle as a sub-project
# inherit the same flag without surprises.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(dazzle SHARED dazzle_capi.c)

if(MSVC)
    # /W4 is roughly comparable to -Wall + -Wextra on GCC/Clang.
    # /D_CRT_SECURE_NO_WARNINGS silences MSVC complaints about strncpy etc.
    target_compile_options(dazzle PRIVATE /O2 /W4 /D_CRT_SECURE_NO_WARNINGS)
    # Windows needs Winsock for the RESP-over-TCP transport.
    target_link_libraries(dazzle PRIVATE ws2_32)
else()
    target_compile_options(dazzle PRIVATE -O2 -Wall -Wextra)
endif()

set_target_properties(dazzle PROPERTIES
    OUTPUT_NAME "dazzle"
    VERSION 0.1.0
    SOVERSION 0
    # Strip the "lib" prefix on Windows so we get dazzle.dll (not libdazzle.dll)
    PREFIX ""
)

# Restore the "lib" prefix on Linux/macOS — CMake's PREFIX="" above clobbers
# the default for those platforms too, so we put it back.
if(NOT WIN32)
    set_target_properties(dazzle PROPERTIES PREFIX "lib")
endif()

install(TARGETS dazzle
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)
