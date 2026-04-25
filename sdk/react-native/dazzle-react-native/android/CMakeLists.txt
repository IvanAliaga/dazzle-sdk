# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Builds `libdazzle_rn_jsi.so` — the JSI HostObject that installs
# `globalThis.__dazzle`. Uses RN's JSI headers for compilation and
# leaves `libjsi.so` unresolved at link time; the Android loader
# resolves it in-process because the RN runtime already loaded it.
#
# Same trick we use for `valkey_direct_command` et al. — keeps this
# target's build free of AGP prefab dance + multi-module plumbing.

cmake_minimum_required(VERSION 3.22.1)
project(dazzle_rn_jsi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# The plugin lives under node_modules/dazzle-react-native (via a
# file-dep symlink from each consumer app). RN's JSI headers live at
# <consumer-app>/node_modules/react-native/ReactCommon/jsi.
get_filename_component(PLUGIN_ROOT    "${CMAKE_SOURCE_DIR}/.."     ABSOLUTE)
get_filename_component(CONSUMER_APP   "${CMAKE_SOURCE_DIR}/../../.."
                        ABSOLUTE)
set(RN_ROOT "${CONSUMER_APP}/node_modules/react-native")
if(NOT EXISTS "${RN_ROOT}/ReactCommon/jsi/jsi/jsi.h")
    get_filename_component(CONSUMER_APP_2
        "${CMAKE_SOURCE_DIR}/../../../.." ABSOLUTE)
    set(RN_ROOT "${CONSUMER_APP_2}/node_modules/react-native")
endif()
if(NOT EXISTS "${RN_ROOT}/ReactCommon/jsi/jsi/jsi.h")
    message(FATAL_ERROR
        "Could not locate react-native/ReactCommon/jsi from ${CMAKE_SOURCE_DIR}. "
        "Make sure the consumer app has react-native installed.")
endif()

add_library(dazzle_rn_jsi SHARED
    "${PLUGIN_ROOT}/cpp/DazzleJSI.cpp"
    "${CMAKE_SOURCE_DIR}/src/main/jni/dazzle_rn_jsi.cpp")

target_include_directories(dazzle_rn_jsi PRIVATE
    "${PLUGIN_ROOT}/cpp"
    "${RN_ROOT}/ReactCommon/jsi")

target_link_libraries(dazzle_rn_jsi
    android
    log)

# Tell the linker it's fine if libjsi / Dazzle C symbols are
# unresolved at link time — both sets are satisfied at runtime when
# this .so is dlopen'd into the RN process (React Native AAR hosts
# libjsi.so; the Dazzle AAR hosts libvalkey-server / libdazzle.so).
target_link_options(dazzle_rn_jsi PRIVATE
    "-Wl,--unresolved-symbols=ignore-all")
