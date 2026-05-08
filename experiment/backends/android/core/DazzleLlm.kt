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

        @JvmStatic private external fun nInit(
            modelPath: String,
            nCtx: Int, nBatch: Int, nThreads: Int,
            kvCacheTypeOrdinal: Int, flashAttn: Boolean, useMlock: Boolean,
        ): Long
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
         *
         * Memory knobs (all default to the published-paper configuration):
         * - [nCtx]           context window. 2048 fits a 5-passage RAG
         *                    prompt + 64-token answer with margin.
         * - [nBatch]         logical prefill batch. Defaults to 512.
         *                    Lowering it shrinks the prefill compute
         *                    scratch (50-80 MB on Qwen 1.5B) at a small
         *                    prefill-time cost on prompts longer than the
         *                    batch.
         * - [kvCacheType]    [KvCacheType.F16] is the paper default. The
         *                    KV cache for Qwen 1.5B at n_ctx=2048 is
         *                    ~470 MB in F16; Q8_0 halves it; Q4_0 quarters
         *                    it. The bench harness records the choice so
         *                    any F1 delta is attributable.
         * - [flashAttention] cuts attention scratch from O(n²) to O(n).
         *                    Defaults to `CpuFeatures.hasFp16()`: ON for
         *                    ARMv8.2 chips with native fp16 (A75/A76+),
         *                    OFF for v8.0 cores (A53/A73) where the
         *                    flash-attn fp16↔fp32 fallback is slower
         *                    AND uses more working memory.
         * - [useMlock]       pins the model weights into resident RAM via
         *                    `mlock()`. Off by default. On 4 GB devices
         *                    where EMUI iAware aggressively pages out the
         *                    1 GB Qwen-1.5B mmap mid-decode, locking the
         *                    weights is the difference between the bench
         *                    finishing and freezing at a random query.
         *                    Numerically a no-op — same weights via the
         *                    same code path, they just stay resident.
         */
        fun open(
            context: Context,
            modelPath: String,
            nCtx: Int = 2048,
            nBatch: Int = 512,
            nThreads: Int = Runtime.getRuntime().availableProcessors().coerceAtMost(4),
            kvCacheType: KvCacheType = KvCacheType.F16,
            flashAttention: Boolean = CpuFeatures.hasFp16(),
            useMlock: Boolean = false,
        ): DazzleLlm {
            val resolved = ensureInternalCopy(context, modelPath)
            val handle   = nInit(
                resolved,
                nCtx, nBatch, nThreads,
                kvCacheType.ordinal, flashAttention, useMlock,
            )
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
