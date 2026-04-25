// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// JNI entry point that installs the Dazzle JSI HostObject onto the
// current React Native JS runtime.
//
// Usage from Kotlin:
//   external fun installJsi(runtimePtr: Long)
//   installJsi(reactContext.javaScriptContextHolder?.get() ?: 0)

#include <jni.h>
#include <jsi/jsi.h>
#include "DazzleJSI.h"

extern "C"
JNIEXPORT void JNICALL
Java_dev_dazzle_rn_DazzleReactNativeModule_nativeInstallJsi(
    JNIEnv* /*env*/, jobject /*this*/, jlong runtimePtr) {
    if (runtimePtr == 0) return;
    auto* rt = reinterpret_cast<facebook::jsi::Runtime*>(runtimePtr);
    dazzle::installJsi(*rt);
}
