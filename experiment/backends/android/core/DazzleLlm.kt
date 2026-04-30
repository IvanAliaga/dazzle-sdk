// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.content.Context
import java.io.File

/**
 * On-device LLM text generator — llama.cpp + any GGUF checkpoint.
 *
 * Sibling of [DazzleEmbedder]: same native library (libllamacpp-jni.so)
 * and same model format (GGUF), but a separate llama_context because the
 * embedder forces `embeddings=true` + mean pooling and generation needs
 * neither. Sampling is **greedy** (argmax) so runs are reproducible and
 * comparisons across prompts / models aren't noisy.
 *
 * Expected model layout on disk:
 *   <filesDir>/gen/<modelFile>.gguf
 *
 * Push pattern (mirrors DazzleEmbedder):
 *   adb push qwen2.5-0.5b-instruct-q4_k_m.gguf /data/local/tmp/
 *   adb shell run-as <pkg> cp /data/local/tmp/qwen2.5-0.5b-instruct-q4_k_m.gguf files/gen/
 *
 * Thread-safety: one [DazzleLlm] owns one llama.cpp context; the native
 * context is NOT thread-safe. Use one LLM per worker if you fan out.
 */
class DazzleLlm private constructor(
    private val handle: Long,
    val modelPath: String,
) : AutoCloseable {

    init {
        check(handle != 0L) { "llama.cpp LLM init failed — see logcat LlamaCppJNI" }
    }

    /**
     * Greedy (argmax) generation. Returns the raw decoded text — no prompt
     * echo, no stop-token trimming beyond the model's own EOG. The caller
     * is responsible for parsing out the answer span if the prompt used
     * a chat template.
     */
    fun generate(prompt: String, maxNewTokens: Int = 128): String =
        nGenerate(handle, prompt, maxNewTokens)
            ?: error("llama.cpp generate returned null — see logcat LlamaCppJNI")

    /** Wall-clock μs for the prefill (tokenize+decode of the prompt). */
    fun lastPrefillUs(): Long = nLastPrefillUs(handle)

    /** Wall-clock μs for the token-by-token decode loop. */
    fun lastDecodeUs():  Long = nLastDecodeUs(handle)

    /** Prompt length (tokens) from the most recent [generate] call. */
    fun lastPromptTokens(): Int = nLastPromptTokens(handle)

    /** Newly generated token count (excludes prompt) from last [generate]. */
    fun lastNewTokens():    Int = nLastNewTokens(handle)

    override fun close() = nFree(handle)

    companion object {
        init { System.loadLibrary("llamacpp-jni") }

        @JvmStatic private external fun nInit(modelPath: String, nCtx: Int, nThreads: Int): Long
        @JvmStatic private external fun nGenerate(handle: Long, prompt: String, maxNewTokens: Int): String?
        @JvmStatic private external fun nLastPrefillUs(handle: Long): Long
        @JvmStatic private external fun nLastDecodeUs (handle: Long): Long
        @JvmStatic private external fun nLastPromptTokens(handle: Long): Int
        @JvmStatic private external fun nLastNewTokens   (handle: Long): Int
        @JvmStatic private external fun nFree(handle: Long)

        /**
         * Open a GGUF generator. [modelPath] may point at either
         *   <filesDir>/gen/<file>.gguf (already copied)
         *   or a /data/local/tmp/... / /sdcard/... path (copied on first use).
         */
        fun open(
            context: Context,
            modelPath: String,
            nCtx: Int = 2048,
            nThreads: Int = Runtime.getRuntime().availableProcessors().coerceAtMost(4),
        ): DazzleLlm {
            val resolved = ensureInternalCopy(context, modelPath)
            val handle   = nInit(resolved, nCtx, nThreads)
            return DazzleLlm(handle, resolved)
        }

        fun defaultPath(context: Context, modelFile: String): String =
            File(File(context.filesDir, "gen").apply { mkdirs() }, modelFile).absolutePath

        private fun ensureInternalCopy(context: Context, sourcePath: String): String {
            val src  = File(sourcePath)
            val dest = File(File(context.filesDir, "gen").apply { mkdirs() }, src.name)
            if (src.canonicalPath == dest.canonicalPath) return dest.absolutePath
            if (!dest.exists() || dest.length() != src.length()) {
                src.copyTo(dest, overwrite = true)
            }
            return dest.absolutePath
        }
    }
}
