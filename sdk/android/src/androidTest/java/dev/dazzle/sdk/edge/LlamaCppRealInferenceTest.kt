// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Real-inference smoke test — loads an actual GGUF file, asks the
 * model for a single greeting, and checks we got back non-empty
 * text. Skips (via `Assume`) if the file isn't staged on the
 * device so the suite still runs on CI devices without a model.
 *
 * Stage the model once:
 *
 * ```
 * adb push ~/Downloads/qwen.gguf /data/local/tmp/qwen.gguf
 * adb shell chmod 644 /data/local/tmp/qwen.gguf
 * ```
 *
 * Then run:
 *
 * ```
 * ./gradlew :connectedDebugAndroidTest \
 *   -Pandroid.testInstrumentationRunnerArguments.class=\
 *      dev.dazzle.sdk.edge.LlamaCppRealInferenceTest
 * ```
 */
@RunWith(AndroidJUnit4::class)
class LlamaCppRealInferenceTest {

    /** Where the host-side `adb push` dropped the file. `/data/local/tmp`
     *  is world-readable on user-debug / engineering builds and doesn't
     *  need MANAGE_EXTERNAL_STORAGE — saves adding a manifest permission
     *  just for a smoke test. See the class KDoc for the push command. */
    private val modelFile: File = File("/data/local/tmp/qwen.gguf")

    @Test
    fun completeReturnsNonEmptyGreeting(): Unit = runBlocking {
        assumeTrue(
            "GGUF not staged at $modelFile — push it with `adb push …/qwen.gguf /sdcard/Download/qwen.gguf`",
            modelFile.isFile,
        )

        val llm = LlamaCppClient(
            modelFile = modelFile,
            // Keep the smoke test fast: 2 k context, short max_tokens,
            // greedy-ish sampling so the output is deterministic.
            nCtx = 1024,
            maxTokens = 32,
            temperature = 0.0f,   // greedy — 0 disables the dist sampler
            topP = 1.0f,
            nThreads = 4,
        )
        try {
            val reply = llm.complete(
                messages = listOf(Message(Role.user, "Say hi in one short sentence.")),
                tools    = emptyList(),
            )
            val text = when (reply) {
                is Completion.Text      -> reply.message.content
                is Completion.ToolCalls -> "(unexpected tool call) " + reply.message.toolCalls.joinToString()
            }
            // Not a string-match test — we don't want to pin the
            // exact output. Just proves that end-to-end tokenise +
            // decode + detokenise + return wired up correctly.
            assertTrue("model produced empty reply", text.isNotBlank())
            android.util.Log.i("LlamaCppSmoke", "reply=\"$text\"")
        } finally {
            llm.close()
        }
    }

    @Test
    fun streamEmitsMultipleTextDeltas(): Unit = runBlocking {
        assumeTrue(
            "GGUF not staged at $modelFile",
            modelFile.isFile,
        )

        val llm = LlamaCppClient(
            modelFile = modelFile,
            nCtx = 1024,
            maxTokens = 16,
            temperature = 0.0f,
            topP = 1.0f,
            nThreads = 4,
        )
        try {
            val deltas = llm.stream(
                messages = listOf(Message(Role.user, "Count: one, two,")),
                tools    = emptyList(),
            ).toList()
            val texts = deltas.filterIsInstance<Delta.Text>()
            assertTrue("no text deltas emitted", texts.isNotEmpty())
            assertTrue("stream must end with Delta.End", deltas.last() == Delta.End)
            android.util.Log.i(
                "LlamaCppSmoke",
                "got ${texts.size} text deltas: \"${texts.joinToString("") { it.chunk }}\""
            )
        } finally {
            llm.close()
        }
    }
}
