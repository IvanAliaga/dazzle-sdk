// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.dazzle.sdk.DazzleException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Smoke tests for the llama.cpp JNI binding. Verifies the native
 * library is linked correctly, exports the expected symbols, and
 * rejects bad inputs gracefully — without requiring a real GGUF
 * model on the device, so the suite runs in CI.
 *
 * Real inference tests with a small GGUF live in
 * `LlamaCppClientSmokeTest` (manual, requires a ~100 MB model on
 * the device's external storage).
 */
@RunWith(AndroidJUnit4::class)
class LlamaNativeInstrumentedTest {

    @Test
    fun backendInitDoesNotCrash() {
        // Idempotent — safe to call many times.
        LlamaNative.nBackendInit()
        LlamaNative.nBackendInit()
    }

    @Test
    fun loadMissingModelReturnsZeroInsteadOfCrashing() {
        LlamaNative.nBackendInit()
        val handle = LlamaNative.nLoadModel(
            "/does/not/exist/nope.gguf",
            /*nGpuLayers*/ 0,
        )
        assertEquals("missing file must return 0", 0L, handle)
    }

    @Test
    fun llamaCppClientRaisesOnMissingModel() {
        // Public API wraps the nLoadModel == 0 case in a typed
        // DazzleException so consumers don't see raw JNI zeros.
        val missing = File("/does/not/exist/nope.gguf")
        try {
            LlamaCppClient(modelFile = missing)
            fail("expected ModelLoadFailed")
        } catch (e: DazzleException.ModelLoadFailed) {
            assertFalse(e.message.orEmpty().isEmpty())
        }
    }

    @Test
    fun freeOnZeroHandlesIsNoOp() {
        // Null / 0 handles must be safe to pass to the free* APIs —
        // callers that hit an early-exit in construction rely on that
        // to avoid conditional cleanup boilerplate.
        LlamaNative.nFreeContext(0L)
        LlamaNative.nFreeModel(0L)
    }
}
