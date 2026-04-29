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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/**
 * R13 validation: measure query latency while a writer thread is actively
 * appending new vectors to the index — the RAG live-append pattern.
 *
 * Compares two regimes against the quiet baseline:
 *
 *   A. quiet       — readers run, no writer.
 *   B. live-append — readers run while a single writer hammers HADD/addPoint.
 *
 * If R13 works, the writer's graph inserts under shared_lock let readers
 * proceed; the p50/p95 lift from A to B should be a small fraction rather
 * than the pre-R13 full-exclusion multiple.
 */
object VectorLiveIngestBench {

    private const val TAG = "VecLive"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val dim: Int = 768,
        val nSeed: Int = 10_000,
        val nAppend: Int = 5_000,
        val readerThreads: Int = 4,
        val nQueriesPerPhase: Int = 2_000,
        val k: Int = 10,
        val ef: Int = 10,
        val seed: Long = 42L,
    )

    fun run(context: Context, cfg: Config = Config()) {
        Log.i(TAG, "══ VectorLiveIngestBench dim=${cfg.dim} seed=${cfg.nSeed} append=${cfg.nAppend} readers=${cfg.readerThreads} ══")

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(context, DazzleConfig(
            port        = 6381,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)

        val rng = Random(cfg.seed)
        val seedVecs   = Array(cfg.nSeed)   { FloatArray(cfg.dim) { rng.nextFloat() * 2f - 1f } }
        val appendVecs = Array(cfg.nAppend) { FloatArray(cfg.dim) { rng.nextFloat() * 2f - 1f } }
        val queries    = Array(cfg.nQueriesPerPhase) { seedVecs[rng.nextInt(cfg.nSeed)].copyOf() }

        val results = linkedMapOf<String, Any?>()
        try {
            val client = DazzleServer.client()
            // R17: pre-allocate capacity for seed + appends so the live
            // phase never triggers HNSW resizeIndex — that's the last
            // event that still takes unique_lock(schema->mtx) and fences
            // concurrent readers. +256 gives a tiny safety margin.
            //
            // R18: efConstruction=200 (default 400) shortens the time each
            // addPoint spends inside hnswlib's internal per-link locks
            // during live-append. Recall delta at query time is small
            // because the query-side ef_runtime stays as configured.
            val idx = client.vectorIndex(
                name            = "live_d${cfg.dim}",
                hashPrefix      = "live:d${cfg.dim}:",
                vectorField     = "emb",
                dim             = cfg.dim,
                algorithm       = VectorIndex.Algorithm.HNSW,
                metric          = VectorIndex.Metric.COSINE,
                initialCapacity = cfg.nSeed + cfg.nAppend + 256,
                efConstruction  = 200,
            )
            check(idx.create()) { "live index create failed" }
            val seedIds = Array(cfg.nSeed) { "live:d${cfg.dim}:s$it" }
            idx.addBatchDirect(seedIds, seedVecs)

            // Warm-up (discarded) — prime code paths.
            for (i in 0 until 50) idx.searchDirect(queries[i], cfg.k, efRuntime = cfg.ef)

            Log.i(TAG, "── phase A: quiet (readers only) ──")
            results["quiet"] = readerPhase(idx, cfg, queries)

            Log.i(TAG, "── phase B: live-append (readers + writer) ──")
            results["live_append"] = readerPhaseWithWriter(idx, cfg, queries, appendVecs)
        } finally {
            try { DazzleServer.stop() } catch (_: Throwable) {}
        }

        val out = linkedMapOf<String, Any?>(
            "type"      to "vector_live_ingest_bench",
            "timestamp" to java.time.Instant.now().toString(),
            "device"    to collectDeviceInfo(),
            "config"    to mapOf(
                "dim"               to cfg.dim,
                "n_seed"            to cfg.nSeed,
                "n_append"          to cfg.nAppend,
                "reader_threads"    to cfg.readerThreads,
                "queries_per_phase" to cfg.nQueriesPerPhase,
                "k"                 to cfg.k,
                "ef_runtime"        to cfg.ef,
            ),
            "results"   to results,
        )
        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "veclive_${safeModel}_${ts}.json"
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

    /** N readers race through queries[0..nQueriesPerPhase). No writer. */
    private fun readerPhase(
        idx: VectorIndex,
        cfg: Config,
        queries: Array<FloatArray>,
    ): Map<String, Any?> {
        val (lat, wallNs) = driveReaders(idx, cfg, queries, writerRunning = null)
        val qps = cfg.nQueriesPerPhase.toDouble() / (wallNs / 1e9)
        val stats = latencyStats(lat)
        Log.i(TAG, "  quiet wall=${wallNs / 1_000_000L}ms qps=${"%.1f".format(qps)} p50=${stats["p50"]}µs p95=${stats["p95"]}µs")
        return linkedMapOf(
            "wall_ms"       to (wallNs / 1_000_000L),
            "qps"           to qps,
            "search_lat_us" to stats,
        )
    }

    /** Readers + a single writer that appends appendVecs concurrently. */
    private fun readerPhaseWithWriter(
        idx: VectorIndex,
        cfg: Config,
        queries: Array<FloatArray>,
        appendVecs: Array<FloatArray>,
    ): Map<String, Any?> {
        val writerRunning = AtomicBoolean(true)
        val writerAppends = AtomicInteger(0)
        val writerStartNs = java.util.concurrent.atomic.AtomicLong(0L)
        val writerDoneNs  = java.util.concurrent.atomic.AtomicLong(0L)
        val writer = Thread({
            val t0 = System.nanoTime()
            writerStartNs.set(t0)
            var i = 0
            while (writerRunning.get() && i < appendVecs.size) {
                val id = "live:d${cfg.dim}:a$i"
                val vec = appendVecs[i]
                // addDirect goes through nAddDirect → index_document, the
                // R13/R14-refactored path: encode outside lock, brief unique
                // for bookkeep, shared for addPoint. This is the exact path
                // RAG append-while-serving takes (one doc at a time).
                idx.addDirect(id, vec)
                writerAppends.incrementAndGet()
                i++
            }
            writerDoneNs.set(System.nanoTime())
        }, "vec-writer")
        writer.start()

        val (lat, wallNs) = driveReaders(idx, cfg, queries, writerRunning)

        writerRunning.set(false)
        writer.join()

        val qps = cfg.nQueriesPerPhase.toDouble() / (wallNs / 1e9)
        val stats = latencyStats(lat)
        val appended = writerAppends.get()
        val writerWallNs = (writerDoneNs.get() - writerStartNs.get()).coerceAtLeast(1L)
        val writerQps = appended.toDouble() / (writerWallNs / 1e9)
        Log.i(TAG, "  live wall=${wallNs / 1_000_000L}ms qps=${"%.1f".format(qps)} p50=${stats["p50"]}µs p95=${stats["p95"]}µs writer_appends=$appended writer_qps=${"%.1f".format(writerQps)}")
        return linkedMapOf(
            "wall_ms"          to (wallNs / 1_000_000L),
            "qps"              to qps,
            "search_lat_us"    to stats,
            "writer_appends"   to appended,
            "writer_wall_ms"   to (writerWallNs / 1_000_000L),
            "writer_append_qps" to writerQps,
        )
    }

    /**
     * Run cfg.readerThreads threads each racing through a shared query
     * cursor. Returns (concat latencies, wall ns for whole phase).
     */
    private fun driveReaders(
        idx: VectorIndex,
        cfg: Config,
        queries: Array<FloatArray>,
        writerRunning: AtomicBoolean?,
    ): Pair<LongArray, Long> {
        val t = cfg.readerThreads
        val latByT = Array(t) { mutableListOf<Long>() }
        val cursor = AtomicInteger(0)
        val ready = CountDownLatch(t)
        val start = CountDownLatch(1)
        val done  = CountDownLatch(t)
        val workers = Array(t) { tid ->
            Thread({
                ready.countDown()
                start.await()
                while (true) {
                    val qi = cursor.getAndIncrement()
                    if (qi >= cfg.nQueriesPerPhase) break
                    val q = queries[qi]
                    val t0 = System.nanoTime()
                    idx.searchDirect(q, cfg.k, efRuntime = cfg.ef)
                    latByT[tid].add((System.nanoTime() - t0) / 1_000L)
                }
                done.countDown()
            }, "vec-reader-$tid")
        }
        workers.forEach { it.start() }
        ready.await()
        val wallStart = System.nanoTime()
        start.countDown()
        done.await()
        val wallNs = System.nanoTime() - wallStart
        // Tell the writer to stop once readers are done.
        writerRunning?.set(false)

        val all = LongArray(cfg.nQueriesPerPhase)
        var o = 0
        for (list in latByT) for (v in list) if (o < all.size) { all[o++] = v }
        while (o < all.size) { all[o] = if (o > 0) all[o - 1] else 0L; o++ }
        return all to wallNs
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
        "model"           to Build.MODEL,
        "manufacturer"    to Build.MANUFACTURER,
        "board"           to Build.BOARD,
        "abi"             to Build.SUPPORTED_ABIS.firstOrNull(),
        "android_version" to Build.VERSION.RELEASE,
        "sdk_int"         to Build.VERSION.SDK_INT,
        "cpu_cores"       to Runtime.getRuntime().availableProcessors(),
    )
}
