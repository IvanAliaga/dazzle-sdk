// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

package dev.dazzle.experiment

import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import com.google.gson.GsonBuilder
import java.io.File

/**
 * E1 embedder latency bench — llama.cpp + any GGUF checkpoint on device.
 *
 * The surface mirrors [VectorDimSweep]: cold-start, per-doc latency across
 * three token-length buckets (~50 / ~100 / ~200 tokens — covers typical RAG
 * chunk sizes), sustained throughput, plus the output-dim read back from the
 * GGUF metadata. One JSON per run under /sdcard/Documents/embed_*.json.
 *
 * Invocation:
 *   adb shell am start -n dev.dazzle.experiment/.ExperimentActivity \
 *     --ez test_storage_only true --es backend embed-bench \
 *     --es embed_model bge-small-en-v1.5-q4_k_m.gguf
 *
 * The GGUF must already be at /sdcard/Download/<model> — the bench copies it
 * once into filesDir on first run (same pattern GemmaInference uses).
 */
object EmbedLatencyBench {

    private const val TAG = "EmbedBench"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val modelFile: String = "bge-small-en-v1.5-q4_k_m.gguf",
        // If null, resolved to <filesDir>/embed/ — the private internal dir
        // owned by the app, 100% reliable read/write without permissions or
        // FUSE quirks. Land models there with:
        //   adb push <file> /data/local/tmp/
        //   adb shell run-as <pkg> mkdir -p files/embed
        //   adb shell run-as <pkg> cp /data/local/tmp/<file> files/embed/
        // (app must be debuggable — our debug builds are).
        val modelSource: String? = null,
        val nDocsPerLen: Int = 100,
        val warmup: Int = 10,
        val nCtx: Int = 512,
        // Approximate token counts — real tokenisation happens inside llama.cpp,
        // so these are just target lengths in characters that roughly land in
        // the wanted token bucket for BGE's WordPiece (~4 chars/token avg).
        val lengths: List<Int> = listOf(200, 400, 800),
    )

    fun run(context: Context, cfg: Config = Config()) {
        Log.i(TAG, "══ EmbedLatencyBench model=${cfg.modelFile} ══")

        val sourceDir = cfg.modelSource?.let { File(it) }
            ?: File(context.filesDir, "embed").apply { mkdirs() }
        val source = File(sourceDir, cfg.modelFile)
        check(source.exists()) {
            "GGUF not found at ${source.absolutePath}. Push with: " +
                "adb push ${cfg.modelFile} ${sourceDir.absolutePath}/"
        }

        // Cold start = time to open the embedder from a clean state. Includes
        // the one-time copy-into-filesDir on first run; subsequent runs skip
        // the copy. We time BOTH paths to know what users pay on first launch
        // vs steady state.
        val coldStart0 = System.nanoTime()
        val embedder = DazzleEmbedder.open(
            context,
            source.absolutePath,
            nCtx = cfg.nCtx,
        )
        val coldStartNs = System.nanoTime() - coldStart0
        Log.i(TAG, "cold start: ${coldStartNs / 1_000_000L} ms   n_embd=${embedder.outputDim}")

        val perLen = linkedMapOf<String, Any?>()
        try {
            for (len in cfg.lengths) {
                Log.i(TAG, "── len≈${len} chars, n=${cfg.nDocsPerLen} ──")
                perLen["len_$len"] = runForLength(embedder, len, cfg)
            }
        } finally {
            embedder.close()
        }

        val out = linkedMapOf<String, Any?>(
            "type" to "embed_latency",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to collectDeviceInfo(),
            "model" to linkedMapOf(
                "file" to cfg.modelFile,
                "output_dim" to embedder.outputDim,
                "n_ctx" to cfg.nCtx,
                "path" to embedder.modelPath,
                "size_bytes" to source.length(),
            ),
            "cold_start_ms" to (coldStartNs / 1_000_000L),
            "results" to perLen,
        )

        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "embed_${safeModel}_${ts}.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fname)
        } catch (_: Exception) {
            File(context.filesDir, fname)
        }
        file.writeText(gson.toJson(out))
        Log.i(TAG, "══ wrote ${file.absolutePath} ══")
    }

    private fun runForLength(
        embedder: DazzleEmbedder,
        targetChars: Int,
        cfg: Config,
    ): Map<String, Any?> {
        val docs = Array(cfg.nDocsPerLen) { syntheticDoc(it, targetChars) }

        // Warm-up — discard. JIT + first llama_decode path-priming.
        val warm = minOf(cfg.warmup, docs.size)
        for (i in 0 until warm) embedder.embed(docs[i])

        val lat = LongArray(cfg.nDocsPerLen)
        val sustainedStart = System.nanoTime()
        var firstVec: FloatArray? = null
        for (i in 0 until cfg.nDocsPerLen) {
            val t0 = System.nanoTime()
            val v = embedder.embed(docs[i])
            lat[i] = (System.nanoTime() - t0) / 1_000L
            if (i == 0) firstVec = v
        }
        val sustainedNs = System.nanoTime() - sustainedStart

        val stats = latencyStats(lat)
        val throughput = cfg.nDocsPerLen * 1e9 / sustainedNs
        Log.i(
            TAG,
            "    p50=${stats["p50"]}µs  p95=${stats["p95"]}µs  p99=${stats["p99"]}µs  " +
                "throughput=${"%.1f".format(throughput)} docs/s",
        )

        return linkedMapOf(
            "n_docs" to cfg.nDocsPerLen,
            "target_chars" to targetChars,
            "latency_us" to stats,
            "throughput_docs_per_s" to throughput,
            "sustained_total_ms" to (sustainedNs / 1_000_000L),
            // First returned vector — a cheap determinism probe across runs.
            "first_vec_head" to firstVec?.take(4)?.map { it.toDouble() },
        )
    }

    /**
     * Synthetic document — a small LCG-driven mix of high-frequency English
     * words up to [targetChars]. Deterministic per [seed] so runs are
     * comparable across devices without shipping a corpus file.
     */
    private fun syntheticDoc(seed: Int, targetChars: Int): String {
        val pool = arrayOf(
            "the", "of", "and", "to", "in", "a", "is", "that", "for", "it",
            "as", "was", "on", "with", "by", "at", "this", "from", "or", "an",
            "be", "are", "but", "not", "they", "which", "one", "you", "all",
            "were", "when", "we", "there", "can", "said", "use", "each",
            "about", "how", "their", "if", "will", "up", "other", "out",
            "many", "some", "time", "very", "no", "just", "know", "take",
            "into", "year", "your", "good", "new", "people", "them", "only",
        )
        var s = (seed * 1103515245L + 12345L) and 0x7FFFFFFF
        val sb = StringBuilder(targetChars + 8)
        while (sb.length < targetChars) {
            s = (s * 1103515245L + 12345L) and 0x7FFFFFFF
            sb.append(pool[(s % pool.size).toInt()])
            sb.append(' ')
        }
        return sb.toString().trim()
    }

    private fun latencyStats(vs: LongArray): Map<String, Any?> {
        if (vs.isEmpty()) return emptyMap()
        val sorted = vs.copyOf().also { it.sort() }
        fun pct(p: Double): Long = sorted[minOf((sorted.size * p).toInt(), sorted.size - 1)]
        return linkedMapOf(
            "n"   to sorted.size,
            "avg" to sorted.sum().toDouble() / sorted.size,
            "p50" to pct(0.50),
            "p95" to pct(0.95),
            "p99" to pct(0.99),
            "min" to sorted.first(),
            "max" to sorted.last(),
        )
    }

    private fun collectDeviceInfo(): Map<String, Any?> = linkedMapOf(
        "model" to Build.MODEL,
        "manufacturer" to Build.MANUFACTURER,
        "board" to Build.BOARD,
        "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
        "android_version" to Build.VERSION.RELEASE,
        "sdk_int" to Build.VERSION.SDK_INT,
        "cpu_cores" to Runtime.getRuntime().availableProcessors(),
    )
}
