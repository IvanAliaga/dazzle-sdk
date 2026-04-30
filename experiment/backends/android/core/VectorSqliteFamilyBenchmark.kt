// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import com.google.gson.GsonBuilder
import java.io.File
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Focused benchmark for SQLite-family vector paths only.
 *
 * Why this exists:
 * - we need apples-to-apples variants for reviewer mitigation:
 *   sqlite-vec {default, optimized, precompute}
 *   sqlite-vector-ai {default, optimized, precompute}
 * - avoids paying the full multi-backend sweep time when we only need
 *   the SQLite ecosystem numbers for the paper update.
 */
object VectorSqliteFamilyBenchmark {

    private const val TAG = "VecSqliteFamily"
    private val gson = GsonBuilder().setPrettyPrinting().create()
    private val DEFAULT_SWEEP_CONFIGS = listOf(
        Config(nDocs = 200, nQueries = 100),
        Config(nDocs = 1_000, nQueries = 100),
        Config(nDocs = 5_000, nQueries = 100),
        Config(nDocs = 10_000, nQueries = 100),
        Config(nDocs = 20_000, nQueries = 100),
    )

    data class Config(
        val dim: Int = 384,
        val nDocs: Int = 10_000,
        val nQueries: Int = 100,
        val k: Int = 10,
        val warmupQueries: Int = 20,
        val seed: Long = 42L,
    )

    fun run(context: Context, cfg: Config = Config()) {
        Log.i(TAG, "══ VectorSqliteFamily dim=${cfg.dim} N=${cfg.nDocs} q=${cfg.nQueries} ══")
        val results = runOne(context, cfg)
        val out = linkedMapOf<String, Any?>(
            "type" to "vector_sqlite_family_benchmark",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to collectDeviceInfo(),
            "config" to mapOf(
                "dim" to cfg.dim,
                "n_docs" to cfg.nDocs,
                "n_queries" to cfg.nQueries,
                "k" to cfg.k,
                "seed" to cfg.seed,
                "warmup_queries" to cfg.warmupQueries,
            ),
            "results" to results,
        )
        writeOutput(context, out, prefix = "vecbench_sqlite_family")
    }

    fun runSweep(context: Context, configs: List<Config> = DEFAULT_SWEEP_CONFIGS) {
        Log.i(TAG, "══ VectorSqliteFamilySweep configs=${configs.size} ══")
        val cfgOut = mutableListOf<Map<String, Any?>>()
        for (cfg in configs) {
            Log.i(TAG, "── sweep dim=${cfg.dim} N=${cfg.nDocs} q=${cfg.nQueries} ──")
            val results = runOne(context, cfg)
            cfgOut += linkedMapOf(
                "config" to mapOf(
                    "dim" to cfg.dim,
                    "n_docs" to cfg.nDocs,
                    "n_queries" to cfg.nQueries,
                    "k" to cfg.k,
                    "seed" to cfg.seed,
                    "warmup_queries" to cfg.warmupQueries,
                ),
                "results" to results,
            )
        }
        val out = linkedMapOf<String, Any?>(
            "type" to "vector_sqlite_family_sweep_benchmark",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to collectDeviceInfo(),
            "configs" to cfgOut,
        )
        writeOutput(context, out, prefix = "vecbench_sqlite_family_sweep")
    }

    private fun runOne(context: Context, cfg: Config): Map<String, Any?> {
        val rng = Random(cfg.seed)
        val docIds = Array(cfg.nDocs) { "doc:$it" }
        val docVecs = Array(cfg.nDocs) { FloatArray(cfg.dim) { rng.nextFloat() * 2f - 1f } }
        val queryIdx = IntArray(cfg.nQueries) { rng.nextInt(cfg.nDocs) }
        val queryRaw = Array(cfg.nQueries) { qi -> docVecs[queryIdx[qi]].copyOf() }
        val docNorm = Array(cfg.nDocs) { i -> docVecs[i].copyOf().also { l2Normalize(it) } }
        val queryNorm = Array(cfg.nQueries) { i -> queryRaw[i].copyOf().also { l2Normalize(it) } }

        // Ground truth + plain SQLite latency baseline.
        val sqliteCopies = Array(cfg.nDocs) { docVecs[it].copyOf() }
        val sqlite = SqliteBruteforceVector(context, cfg.dim)
        sqlite.create()
        val sqIngestStart = System.nanoTime()
        sqlite.addAll(docIds, sqliteCopies)
        val sqIngestNs = System.nanoTime() - sqIngestStart

        val truthTopK = Array(cfg.nQueries) { Array<String>(cfg.k) { "" } }
        repeat(minOf(cfg.warmupQueries, cfg.nQueries)) { i ->
            sqlite.search(queryRaw[i].copyOf(), cfg.k)
        }
        val sqLatUs = LongArray(cfg.nQueries)
        for (qi in 0 until cfg.nQueries) {
            val t0 = System.nanoTime()
            val res = sqlite.search(queryRaw[qi].copyOf(), cfg.k)
            sqLatUs[qi] = (System.nanoTime() - t0) / 1_000L
            for (j in 0 until cfg.k) truthTopK[qi][j] = if (j < res.size) res[j].first else ""
        }
        val sqBytes = sqlite.dbFileSizeBytes()
        sqlite.close()

        val out = linkedMapOf<String, Any?>(
            "sqlite_plain" to mapOf(
                "algorithm_class" to "linear_scan",
                "variant" to "default",
                "recall_at_k" to 1.0,
                "ingest_total_ms" to (sqIngestNs / 1_000_000.0),
                "ingest_avg_us" to (sqIngestNs / 1_000.0 / cfg.nDocs),
                "search_lat_us" to latencyStats(sqLatUs),
                "db_file_bytes" to sqBytes,
            ),
        )

        out["sqlite_vec_default"] = runSqliteVecVariant(
            context = context,
            cfg = cfg,
            variant = "default",
            normalizeOnAccess = true,
            ids = docIds,
            docs = docVecs,
            queries = queryRaw,
            truthTopK = truthTopK,
        )
        out["sqlite_vec_optimized"] = runSqliteVecVariant(
            context = context,
            cfg = cfg,
            variant = "optimized",
            normalizeOnAccess = false,
            ids = docIds,
            docs = docNorm,
            queries = queryNorm,
            truthTopK = truthTopK,
        )
        out["sqlite_vec_precompute"] = runSqliteVecVariant(
            context = context,
            cfg = cfg,
            variant = "precompute_norm_cache",
            normalizeOnAccess = false,
            ids = docIds,
            docs = docNorm,
            queries = queryNorm,
            truthTopK = truthTopK,
            extraWarmup = cfg.warmupQueries * 4,
        )

        out["sqlite_vector_ai_default"] = runSqliteVectorAiVariant(
            context = context,
            cfg = cfg,
            variant = "default",
            ids = docIds,
            docs = docNorm,
            queries = queryNorm,
            truthTopK = truthTopK,
            quantizeMemoryMb = 16,
            preload = false,
        )
        out["sqlite_vector_ai_optimized"] = runSqliteVectorAiVariant(
            context = context,
            cfg = cfg,
            variant = "optimized",
            ids = docIds,
            docs = docNorm,
            queries = queryNorm,
            truthTopK = truthTopK,
            quantizeMemoryMb = 50,
            preload = false,
        )
        out["sqlite_vector_ai_precompute"] = runSqliteVectorAiVariant(
            context = context,
            cfg = cfg,
            variant = "precompute_preload",
            ids = docIds,
            docs = docNorm,
            queries = queryNorm,
            truthTopK = truthTopK,
            quantizeMemoryMb = 50,
            preload = true,
        )

        return out
    }

    private fun runSqliteVecVariant(
        context: Context,
        cfg: Config,
        variant: String,
        normalizeOnAccess: Boolean,
        ids: Array<String>,
        docs: Array<FloatArray>,
        queries: Array<FloatArray>,
        truthTopK: Array<Array<String>>,
        extraWarmup: Int = 0,
    ): Map<String, Any?> {
        val backend = SqliteVecVector(
            context = context,
            dim = cfg.dim,
            dbName = "vecbench_sqlitevec_${variant.replace(Regex("[^A-Za-z0-9_]"), "_")}",
            normalizeOnAccess = normalizeOnAccess,
        )
        backend.create()
        val ingestStart = System.nanoTime()
        backend.addAll(ids, docs)
        val ingestNs = System.nanoTime() - ingestStart

        val warm = minOf(cfg.nQueries, cfg.warmupQueries + extraWarmup)
        repeat(warm) { i -> backend.search(queries[i], cfg.k) }

        val latUs = LongArray(cfg.nQueries)
        var hits = 0
        var total = 0
        for (qi in 0 until cfg.nQueries) {
            val t0 = System.nanoTime()
            val res = backend.search(queries[qi], cfg.k)
            latUs[qi] = (System.nanoTime() - t0) / 1_000L
            val set = res.map { it.first }.toHashSet()
            val truth = truthTopK[qi].filter { it.isNotEmpty() }.toHashSet()
            hits += set.intersect(truth).size
            total += truth.size
        }
        val recall = if (total > 0) hits.toDouble() / total else 0.0
        val bytes = backend.dbFileSizeBytes()
        backend.close()

        Log.i(TAG, "sqlite-vec/$variant recall@${cfg.k}=${"%.4f".format(recall)} p50=${latencyStats(latUs)["p50"]}µs")
        return mapOf(
            "algorithm_class" to "linear_scan",
            "variant" to variant,
            "normalize_on_access" to normalizeOnAccess,
            "recall_at_k" to recall,
            "ingest_total_ms" to (ingestNs / 1_000_000.0),
            "ingest_avg_us" to (ingestNs / 1_000.0 / cfg.nDocs),
            "search_lat_us" to latencyStats(latUs),
            "db_file_bytes" to bytes,
        )
    }

    private fun runSqliteVectorAiVariant(
        context: Context,
        cfg: Config,
        variant: String,
        ids: Array<String>,
        docs: Array<FloatArray>,
        queries: Array<FloatArray>,
        truthTopK: Array<Array<String>>,
        quantizeMemoryMb: Int,
        preload: Boolean,
    ): Map<String, Any?> {
        val backend = SqliteVectorAiVector(
            context = context,
            dim = cfg.dim,
            dbName = "vecbench_sqlvectorai_${variant.replace(Regex("[^A-Za-z0-9_]"), "_")}",
        )
        backend.create()
        val ingestStart = System.nanoTime()
        backend.addAll(ids, docs)
        val ingestNs = System.nanoTime() - ingestStart

        val quantStart = System.nanoTime()
        backend.finalizeIndex(maxMemoryMb = quantizeMemoryMb, preload = preload)
        val quantNs = System.nanoTime() - quantStart

        val warm = minOf(cfg.nQueries, cfg.warmupQueries)
        repeat(warm) { i -> backend.search(queries[i], cfg.k) }

        val latUs = LongArray(cfg.nQueries)
        var hits = 0
        var total = 0
        for (qi in 0 until cfg.nQueries) {
            val t0 = System.nanoTime()
            val res = backend.search(queries[qi], cfg.k)
            latUs[qi] = (System.nanoTime() - t0) / 1_000L
            val set = res.map { it.first }.toHashSet()
            val truth = truthTopK[qi].filter { it.isNotEmpty() }.toHashSet()
            hits += set.intersect(truth).size
            total += truth.size
        }
        val recall = if (total > 0) hits.toDouble() / total else 0.0
        val bytes = backend.dbFileSizeBytes()
        backend.close()

        Log.i(TAG, "sqlite-vector-ai/$variant recall@${cfg.k}=${"%.4f".format(recall)} p50=${latencyStats(latUs)["p50"]}µs")
        return mapOf(
            "algorithm_class" to "quantized_linear_scan",
            "variant" to variant,
            "quantize_memory_mb" to quantizeMemoryMb,
            "preload" to preload,
            "recall_at_k" to recall,
            "ingest_total_ms" to ((ingestNs + quantNs) / 1_000_000.0),
            "ingest_only_ms" to (ingestNs / 1_000_000.0),
            "quantize_total_ms" to (quantNs / 1_000_000.0),
            "ingest_avg_us" to ((ingestNs + quantNs) / 1_000.0 / cfg.nDocs),
            "search_lat_us" to latencyStats(latUs),
            "db_file_bytes" to bytes,
        )
    }

    private fun latencyStats(vs: LongArray): Map<String, Any?> {
        if (vs.isEmpty()) return emptyMap()
        val sorted = vs.copyOf().also { it.sort() }
        fun pct(p: Double): Long = sorted[minOf((sorted.size * p).toInt(), sorted.size - 1)]
        return linkedMapOf(
            "n" to sorted.size,
            "avg" to sorted.sum().toDouble() / sorted.size,
            "p50" to pct(0.50),
            "p95" to pct(0.95),
            "p99" to pct(0.99),
            "min" to sorted.first(),
            "max" to sorted.last(),
        )
    }

    private fun l2Normalize(v: FloatArray) {
        var s = 0.0
        for (x in v) s += x.toDouble() * x
        val n = sqrt(s).toFloat()
        if (n <= 0f) return
        val inv = 1f / n
        for (i in v.indices) v[i] = v[i] * inv
    }

    private fun collectDeviceInfo(): Map<String, Any?> = linkedMapOf(
        "model" to Build.MODEL,
        "manufacturer" to Build.MANUFACTURER,
        "board" to Build.BOARD,
        "hardware" to Build.HARDWARE,
        "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
        "android_version" to Build.VERSION.RELEASE,
        "sdk_int" to Build.VERSION.SDK_INT,
        "cpu_cores" to Runtime.getRuntime().availableProcessors(),
    )

    private fun writeOutput(
        context: Context,
        payload: Map<String, Any?>,
        prefix: String,
    ) {
        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "${prefix}_${safeModel}_$ts.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fname)
        } catch (_: Exception) {
            File(context.filesDir, fname)
        }
        file.writeText(gson.toJson(payload))
        Log.i(TAG, "══ wrote ${file.absolutePath} ══")
    }
}
