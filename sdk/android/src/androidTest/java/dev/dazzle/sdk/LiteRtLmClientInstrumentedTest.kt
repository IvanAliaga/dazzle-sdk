// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.dazzle.sdk.edge.LiteRtLmClient
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Exercises [LiteRtLmClient] against a real Gemma model. Skipped on
 * every device that doesn't have the model file pre-pushed — we don't
 * want CI to pull a 2.4 GB artifact on every run.
 *
 * To enable locally:
 *
 * ```shell
 * adb push ~/Downloads/gemma-4-E2B-it.litertlm \
 *   /sdcard/Android/data/dev.dazzle.sdk.test/files/
 * ```
 *
 * The first test prints where it expects the file so the adb path
 * stays discoverable.
 */
@RunWith(AndroidJUnit4::class)
class LiteRtLmClientInstrumentedTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun modelFile(): File? {
        // Check a handful of likely locations ordered by how the dev
        // would typically push the file. First hit wins.
        val candidates = listOf(
            File(context.filesDir, "gemma-4-E2B-it.litertlm"),
            File(context.getExternalFilesDir(null), "gemma-4-E2B-it.litertlm"),
            File("/sdcard/Android/data/${context.packageName}/files/gemma-4-E2B-it.litertlm"),
            File("/sdcard/Download/gemma-4-E2B-it.litertlm"),
        )
        return candidates.firstOrNull { it.exists() && it.length() > 1_000_000_000L }
    }

    @Test
    fun completeReturnsTextWhenModelIsPresent() = runBlocking {
        val model = modelFile()
        assumeTrue(
            "Gemma model not found on device — skipping. " +
                "adb push gemma-4-E2B-it.litertlm into " +
                "${context.filesDir.absolutePath}/ to enable.",
            model != null,
        )

        LiteRtLmClient(
            modelFile = model!!,
            context = context,
        ).use { llm ->
            val completion = llm.complete(
                messages = listOf(
                    Message(Role.system, "You are a terse test assistant. Reply with one word."),
                    Message(Role.user, "Say: hello"),
                ),
            )
            val text = (completion as Completion.Text).message.content
            assertTrue(
                "expected non-empty assistant text, got '$text'",
                text.isNotBlank()
            )
        }
    }

    @Test
    fun streamYieldsDeltasThenEnd() = runBlocking {
        val model = modelFile()
        assumeTrue(
            "Gemma model not found — see completeReturnsTextWhenModelIsPresent doc",
            model != null,
        )

        LiteRtLmClient(
            modelFile = model!!,
            context = context,
        ).use { llm ->
            val deltas = llm.stream(
                messages = listOf(
                    Message(Role.user, "Say: hi"),
                ),
            ).toList()

            assertTrue("expected at least one delta, got none", deltas.isNotEmpty())
            assertEquals("last delta must be End", Delta.End, deltas.last())
            val textCount = deltas.filterIsInstance<Delta.Text>().size
            assertTrue(
                "expected at least one text delta, got $textCount",
                textCount > 0,
            )
        }
    }
}

