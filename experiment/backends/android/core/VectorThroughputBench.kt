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
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.VectorIndex
import dev.dazzle.sdk.WipeTarget
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/**
 * Concurrent-query throughput benchmark for dazzle-vector.
 *
 * The single-query p50 sweep in [VectorBenchmark] describes the critical path
 * of one query. The RAG product runs in three modes: single, multi-core
 * parallel queries, and oversubscribed. This harness measures the multi-core
 * dimension: fixed workload, fan queries out across N worker threads, record
 * wall-clock QPS + per-query latency under load. If the R10/R11 kernel wins
 * regress under contention (e.g. shared cache lines in the graph walk), this
 * is where it shows up.
 *
 * Algorithms swept: fp32, sq8, f16, sq8+rerank — all at dim=384 N=10k ef=10.
 *
 * Known bottleneck this harness will expose: `nSearchHandle` in
 * valkeysearch_module.cc takes a per-schema mutex around the graph walk
 * (so `setEf` is safe). Expect near-zero QPS scaling until that lock moves
 * to a per-search local ef. The numbers here are the empirical proof of the
 * need for that fix — keeping the bench is the point.
 *
 * Invoked from adb:
 *   adb shell am start -n dev.dazzle.experiment/.ExperimentActivity \
 *     --es backend vector-throughput
 */
object VectorThroughputBench {

    private const val TAG = "VecThru"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val dim: Int = 384,
        val nDocs: Int = 10_000,
        val nQueries: Int = 500,
        val k: Int = 10,
        val ef: Int = 10,
        val threadCounts: IntArray = intArrayOf(1, 2, 4, 8),
        val seed: Long = 42L,
    )

    fun run(context: Context, cfg: Config = Config()) {
        Log.i(TAG, "══ VectorThroughputBench dim=${cfg.dim} N=${cfg.nDocs} nQ=${cfg.nQueries} threads=${cfg.threadCounts.toList()} ══")

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(context, DazzleConfig(
            port        = 6381,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)

        val rng = Random(cfg.seed)
        val docVecs = Array(cfg.nDocs) { FloatArray(cfg.dim) { rng.nextFloat() * 2f - 1f } }
        val qIdxs = IntArray(cfg.nQueries) { rng.nextInt(cfg.nDocs) }
        val queries = Array(cfg.nQueries) { docVecs[qIdxs[it]].copyOf() }

        val algos = listOf(
            Algo("dazzle_hnsw",        VectorIndex.Algorithm.HNSW,            "vbt"),
            Algo("dazzle_sq8",         VectorIndex.Algorithm.HNSW_SQ8,        "vbtq"),
            Algo("dazzle_f16",         VectorIndex.Algorithm.HNSW_F16,        "vbth"),
            Algo("dazzle_sq8_rerank",  VectorIndex.Algorithm.HNSW_SQ8_RERANK, "vbtr"),
        )

        val results = linkedMapOf<String, Any?>()
        try {
            // Cold-start warmup (discarded) — valkeysearch first-load recall dip.
            runCatching {
                val client = DazzleServer.client()
                val warmIdx = client.vectorIndex(
                    name = "thru_warmup", hashPrefix = "tw:",
                    vectorField = "emb", dim = 8,
                    algorithm = VectorIndex.Algorithm.HNSW,
                    metric = VectorIndex.Metric.COSINE,
                )
                warmIdx.create()
                val ids = Array(32) { "tw:$it" }
                val vs = Array(32) { FloatArray(8) { rng.nextFloat() } }
                warmIdx.addBatchDirect(ids, vs)
                for (i in 0 until 10) warmIdx.searchDirect(vs[i], 3, efRuntime = 10)
            }

            for (a in algos) {
                Log.i(TAG, "── ${a.name} ──")
                results[a.name] = runAlgo(cfg, docVecs, queries, a)
            }
        } finally {
            try { DazzleServer.stop() } catch (_: Throwable) {}
        }

        val out = linkedMapOf<String, Any?>(
            "type" to "vector_throughput_benchmark",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to collectDeviceInfo(),
            "config" to mapOf(
                "dim" to cfg.dim,
                "n_docs" to cfg.nDocs,
                "n_queries" to cfg.nQueries,
                "k" to cfg.k,
                "ef_runtime" to cfg.ef,
                "thread_counts" to cfg.threadCounts.toList(),
            ),
            "results" to results,
        )

        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "vecthru_${safeModel}_${ts}.json"
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

    private data class Algo(
        val name: String,
        val algorithm: VectorIndex.Algorithm,
        val prefix: String,
    )

    private fun runAlgo(
        cfg: Config,
        docVecs: Array<FloatArray>,
        queries: Array<FloatArray>,
        a: Algo,
    ): Map<String, Any?> {
        val client = DazzleServer.client()
        val idx = client.vectorIndex(
            name        = "${a.prefix}_d${cfg.dim}n${cfg.nDocs}",
            hashPrefix  = "${a.prefix}:d${cfg.dim}n${cfg.nDocs}:",
            vectorField = "emb",
            dim         = cfg.dim,
            algorithm   = a.algorithm,
            metric      = VectorIndex.Metric.COSINE,
        )
        check(idx.create()) { "${a.name} create failed" }
        val ids = Array(cfg.nDocs) { "${a.prefix}:d${cfg.dim}n${cfg.nDocs}:$it" }

        val ingestStart = System.nanoTime()
        idx.addBatchDirect(ids, docVecs)
        val ingestNs = System.nanoTime() - ingestStart
        Log.i(TAG, "  ingest ${cfg.nDocs} × dim=${cfg.dim}: ${ingestNs / 1_000_000L} ms")

        // Per-thread-count sweep. Fresh warm-up before each run so caches
        // aren't carrying state across configurations.
        val byThreads = mutableListOf<Map<String, Any?>>()
        for (t in cfg.threadCounts) {
            // Warm-up: 50 sequential queries on the main thread to prime the
            // code path; discarded.
            val warm = minOf(50, queries.size)
            for (i in 0 until warm) idx.searchDirect(queries[i], cfg.k, efRuntime = cfg.ef)

            val latByThread = Array(t) { mutableListOf<Long>() }
            val qCursor = AtomicInteger(0)
            val ready = CountDownLatch(t)
            val start = CountDownLatch(1)
            val done = CountDownLatch(t)
            val workers = Array(t) { tid ->
                Thread({
                    ready.countDown()
                    start.await()
                    while (true) {
                        val qi = qCursor.getAndIncrement()
                        if (qi >= cfg.nQueries) break
                        val q = queries[qi]
                        val t0 = System.nanoTime()
                        idx.searchDirect(q, cfg.k, efRuntime = cfg.ef)
                        latByThread[tid].add((System.nanoTime() - t0) / 1_000L)
                    }
                    done.countDown()
                }, "vecthru-${a.name}-$tid")
            }
            workers.forEach { it.start() }
            ready.await()
            val wallStart = System.nanoTime()
            start.countDown()
            done.await()
            val wallNs = System.nanoTime() - wallStart

            val allLat = LongArray(cfg.nQueries).also {
                var o = 0
                for (list in latByThread) for (v in list) it[o++] = v
                // If any worker undershot (shouldn't happen), fill remainder
                // with the last value to keep the array dense.
                while (o < it.size) { it[o] = if (o > 0) it[o-1] else 0L; o++ }
            }
            val qps = cfg.nQueries.toDouble() / (wallNs / 1e9)
            val stats = latencyStats(allLat)
            byThreads += linkedMapOf(
                "threads"         to t,
                "wall_ms"         to (wallNs / 1_000_000L),
                "qps"             to qps,
                "search_lat_us"   to stats,
            )
            Log.i(TAG, "  T=$t  wall=${wallNs / 1_000_000L}ms  qps=${"%.1f".format(qps)}  p50=${stats["p50"]}µs  p95=${stats["p95"]}µs")
        }

        return linkedMapOf(
            "ingest_total_ms" to (ingestNs / 1_000_000L),
            "ingest_avg_us"   to (ingestNs / 1_000.0 / cfg.nDocs),
            "by_threads"      to byThreads,
        )
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
        "hardware" to Build.HARDWARE,
        "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
        "android_version" to Build.VERSION.RELEASE,
        "sdk_int" to Build.VERSION.SDK_INT,
        "cpu_cores" to Runtime.getRuntime().availableProcessors(),
    )
}
