// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

/**
 * Thin JNI surface over the embedded llama.cpp. The real inference
 * lives in `core/platform/dazzle_llama.cpp` + `dazzle_llama_jni.c`;
 * this file only declares the native-method signatures so the
 * Kotlin compiler records them in the .class and the linker keeps
 * the matching symbols in `libdazzle.so`.
 *
 * Public API is [LlamaCppClient]. These externals are internal.
 */
internal object LlamaNative {
    init {
        // libdazzle.so is already loaded by DazzleServer.init, so
        // this is a no-op most of the time — but calling it here
        // gives a clean error if the AAR was stripped of its native
        // lib. Mirrors the VectorIndex.companion pattern.
        try { System.loadLibrary("dazzle") } catch (_: UnsatisfiedLinkError) {}
    }

    @JvmStatic external fun nBackendInit()

    /** Load a GGUF model file. Returns a handle (>0) or 0 on failure. */
    @JvmStatic external fun nLoadModel(path: String, nGpuLayers: Int): Long

    /** Release model weights. Must be called after every successful load. */
    @JvmStatic external fun nFreeModel(handle: Long)

    /** Build an inference context from a loaded model. Returns handle or 0. */
    @JvmStatic external fun nNewContext(modelHandle: Long, nCtx: Int, nThreads: Int): Long

    /** Release inference context. */
    @JvmStatic external fun nFreeContext(handle: Long)

    /**
     * Run one generation pass. `callback.onToken(piece)` is invoked
     * for each decoded UTF-8 piece; return `false` from it to cancel.
     * Returns number of tokens emitted on success, or a negative
     * `DAZZLE_LLAMA_E_*` code on failure.
     */
    @JvmStatic external fun nGenerate(
        ctxHandle: Long,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        seed: Int,
        callback: LlamaTokenCallback,
    ): Int
}

/**
 * Consumer-visible callback invoked from the native decode loop for
 * each token. Return `true` to keep going, `false` to request a
 * graceful cancel at the next token boundary.
 */
fun interface LlamaTokenCallback {
    fun onToken(piece: String): Boolean
}
