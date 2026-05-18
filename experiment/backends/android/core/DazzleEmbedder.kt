// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.content.Context
import java.io.File

/**
 * On-device text embedder — llama.cpp + any GGUF checkpoint.
 *
 * The surface is ours and the runtime is vendor-neutral (llama.cpp, MIT,
 * community-owned). Swapping to a different base model (BGE variants, E5,
 * MiniLM, Nomic) is a file swap — the code path is identical. The same
 * `.so` will later serve LLM generation in E2, so the SDK ships a single
 * native library for the whole RAG pipeline.
 *
 * Expected model layout on disk:
 *   <modelDir>/<modelFile>.gguf   — the GGUF checkpoint (tokenizer included)
 *
 * Push pattern (matches GemmaInference):
 *   adb push bge-small-en-v1.5-q4_k_m.gguf /sdcard/Download/
 *   → the bench copies once into filesDir on first run
 *
 * Thread-safety: one [DazzleEmbedder] owns one llama.cpp context; the native
 * context is NOT thread-safe. Use one embedder per worker if you fan out,
 * or synchronise on [embed].
 */
/**
 * Quantisation choice for the runtime KV cache. Listed in the order the
 * JNI side expects (the ordinal is what crosses the boundary). F16 is
 * the published-paper default; Q8_0 / Q4_0 are opt-in for low-RAM
 * targets where shrinking the KV cache is the difference between a run
 * fitting in device memory or being killed by EMUI iAware.
 */
enum class KvCacheType { F16, Q8_0, Q4_0 }

class DazzleEmbedder private constructor(
    private val handle: Long,
    val modelPath: String,
) : AutoCloseable {

    /** Output embedding dimension, read from the GGUF metadata. */
    val outputDim: Int = nOutputDim(handle)

    init {
        check(handle != 0L) { "llama.cpp init failed — see logcat LlamaCppJNI" }
    }

    /**
     * Embed one document. Returns an L2-normalised FloatArray of length
     * [outputDim]. Mean-pooling is applied inside llama.cpp per the context
     * config; the JNI shim re-normalises on the way out for determinism.
     */
    fun embed(text: String): FloatArray = nEmbed(handle, text)
        ?: error("llama.cpp embed returned null — see logcat LlamaCppJNI")

    override fun close() = nFree(handle)

    companion object {
        init { System.loadLibrary("llamacpp-jni") }

        @JvmStatic private external fun nInit(
            modelPath: String,
            nCtx: Int, nBatch: Int, nThreads: Int,
            kvCacheTypeOrdinal: Int, flashAttn: Boolean, useMlock: Boolean,
        ): Long
        @JvmStatic private external fun nEmbed(handle: Long, text: String): FloatArray?
        @JvmStatic private external fun nOutputDim(handle: Long): Int
        @JvmStatic private external fun nFree(handle: Long)

        /**
         * Open a GGUF embedder from [modelPath]. If the file isn't already
         * in [Context.getFilesDir], it is copied there once (matches the
         * pattern GemmaInference uses for its .litertlm model).
         *
         * @param nCtx          context window, in tokens. Default 512 keeps
         *                      BGE-small / E5-small style passages well under
         *                      truncation.
         * @param nBatch        logical batch size for prefill. Defaults to
         *                      `min(nCtx, 256)`. Lower values shrink the
         *                      compute scratch (helpful on 4 GB devices).
         * @param nThreads      worker threads (capped at 4 by default).
         * @param kvCacheType   KV quantisation. [KvCacheType.F16] is the
         *                      paper default. The KV cache is reset on
         *                      every embed call so the choice is mostly
         *                      cosmetic for embedders, but the knob is
         *                      kept symmetric with [DazzleLlm].
         * @param flashAttention enables llama.cpp's flash-attention path.
         *                      Defaults to `CpuFeatures.hasFp16()`: ON for
         *                      ARMv8.2 chips (A75/A76+), OFF for v8.0
         *                      cores (A53/A73). Without native fp16 the
         *                      flash-attn path emulates via fp16↔fp32
         *                      conversion which is slower AND uses more
         *                      working memory than the standard path —
         *                      exactly the case that froze Kirin 659 at
         *                      `embed passage 0/2000`.
         * @param useMlock      pins the model weights into resident RAM
         *                      via `mlock()`. Off by default — most
         *                      devices don't need it and the lock is a
         *                      hard failure mode on locked-down systems.
         *                      The JNI raises RLIMIT_MEMLOCK to
         *                      RLIM_INFINITY at first init so the lock
         *                      can succeed on multi-GB models when the
         *                      caller opts in. Numerically a no-op —
         *                      same weights via the same code path,
         *                      they just don't get evicted by EMUI
         *                      iAware mid-decode.
         */
        fun open(
            context: Context,
            modelPath: String,
            nCtx: Int = 512,
            nBatch: Int = nCtx.coerceAtMost(256),
            nThreads: Int = Runtime.getRuntime().availableProcessors().coerceAtMost(4),
            kvCacheType: KvCacheType = KvCacheType.F16,
            flashAttention: Boolean = CpuFeatures.hasFp16(),
            useMlock: Boolean = false,
        ): DazzleEmbedder {
            val resolved = ensureInternalCopy(context, modelPath)
            val handle   = nInit(
                resolved,
                nCtx, nBatch, nThreads,
                kvCacheType.ordinal, flashAttention, useMlock,
            )
            return DazzleEmbedder(handle, resolved)
        }

        /**
         * Convention used by the bench runner: models live under
         * <filesDir>/embed/<modelName>.gguf. Push new bases to
         * /sdcard/Download/<modelName>.gguf and they are copied on first
         * use.
         */
        fun defaultPath(context: Context, modelFile: String): String =
            File(File(context.filesDir, "embed").apply { mkdirs() }, modelFile).absolutePath

        private fun ensureInternalCopy(context: Context, sourcePath: String): String {
            val src  = File(sourcePath)
            val dest = File(File(context.filesDir, "embed").apply { mkdirs() }, src.name)
            if (src.canonicalPath == dest.canonicalPath) return dest.absolutePath
            if (!dest.exists() || dest.length() != src.length()) {
                src.copyTo(dest, overwrite = true)
            }
            return dest.absolutePath
        }
    }
}
