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
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Realistic-dim sweep: 384 / 768 / 1536, N=10k.
 *
 * Compares dazzle's four HNSW variants (f32, sq8, sq8+rerank, f16) against
 * SQLiteAI's sqlite-vector (brute-force SIMD, no ANN). sqlite-vec (Alex
 * Garcia) and ObjectBox are excluded: the former's curve is predictable
 * (linearly slower than sqlite-vector at the same SIMD precision because
 * it lacks SQLiteAI's quantise-scan), the latter bakes a fixed dim into
 * its @HnswIndex schema so a dim sweep is impossible without rebuilding
 * six separate Kotlin classes.
 *
 * Recall ground truth is a brute-force top-k over the same corpus,
 * computed inside the bench. A small query set (nQueries=100) keeps that
 * computation tractable even at 1536 dim (100 × 10k × 1536 ≈ 1.5B FMA ≈
 * a few seconds).
 */
object VectorDimSweep {

    private const val TAG = "VecDim"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val dim: Int,
        val nDocs: Int = 10_000,
        val nQueries: Int = 100,
        val k: Int = 10,
        val ef: Int = 10,
        val seed: Long = 42L,
    )

    private val DEFAULT_CONFIGS = listOf(
        Config(dim = 384),
        Config(dim = 768),
        Config(dim = 1536),
    )

    fun run(context: Context, configs: List<Config> = DEFAULT_CONFIGS) {
        Log.i(TAG, "══ VectorDimSweep: ${configs.size} configs ══")

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(context, DazzleConfig(
            port        = 6381,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)

        val allResults = mutableListOf<Map<String, Any?>>()
        try {
            for (cfg in configs) {
                Log.i(TAG, "── cfg dim=${cfg.dim} N=${cfg.nDocs} ──")
                allResults += runConfig(context, cfg)
            }
        } finally {
            try { DazzleServer.stop() } catch (_: Throwable) {}
        }

        val out = linkedMapOf<String, Any?>(
            "type" to "vector_dim_sweep",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to collectDeviceInfo(),
            "configs" to allResults,
        )

        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "vecdim_${safeModel}_${ts}.json"
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

    private fun runConfig(context: Context, cfg: Config): Map<String, Any?> {
        val rng = Random(cfg.seed)
        val docVecs = Array(cfg.nDocs) { FloatArray(cfg.dim) { rng.nextFloat() * 2f - 1f } }
        val qIdxs = IntArray(cfg.nQueries) { rng.nextInt(cfg.nDocs) }
        val queries = Array(cfg.nQueries) { docVecs[qIdxs[it]].copyOf() }

        // Brute-force cosine ground truth. Pre-normalise doc copies once.
        val truthStart = System.nanoTime()
        val docNorm = Array(cfg.nDocs) { i ->
            val v = docVecs[i].copyOf()
            l2normalise(v)
            v
        }
        val truthTopK = Array(cfg.nQueries) { qi ->
            val q = queries[qi].copyOf()
            l2normalise(q)
            topKIndices(docNorm, q, cfg.k)
        }
        val truthNs = System.nanoTime() - truthStart
        Log.i(TAG, "  brute truth dim=${cfg.dim} nQ=${cfg.nQueries}: ${truthNs / 1_000_000L} ms")

        val algos = listOf(
            Algo("dazzle_hnsw",        VectorIndex.Algorithm.HNSW,            "vdh"),
            Algo("dazzle_sq8",         VectorIndex.Algorithm.HNSW_SQ8,        "vdq"),
            Algo("dazzle_f16",         VectorIndex.Algorithm.HNSW_F16,        "vdf"),
            Algo("dazzle_sq8_rerank",  VectorIndex.Algorithm.HNSW_SQ8_RERANK, "vdr"),
        )

        val perAlgo = linkedMapOf<String, Any?>()
        for (a in algos) {
            Log.i(TAG, "  ── ${a.name} ──")
            perAlgo[a.name] = runAlgo(cfg, docVecs, queries, truthTopK, a)
        }

        // SQLiteAI sqlite-vector — brute-force SIMD baseline (no ANN).
        // Guarded so a missing libvector.so doesn't blow up the whole sweep.
        try {
            Log.i(TAG, "  ── sqlite_vector_ai ──")
            perAlgo["sqlite_vector_ai"] = runSqliteVectorAi(context, cfg, docVecs, queries, truthTopK)
        } catch (t: Throwable) {
            Log.e(TAG, "    sqlite_vector_ai failed: ${t.message}")
            perAlgo["sqlite_vector_ai"] = linkedMapOf("error" to (t.message ?: t.javaClass.simpleName))
        }

        return linkedMapOf(
            "dim"          to cfg.dim,
            "n_docs"       to cfg.nDocs,
            "n_queries"    to cfg.nQueries,
            "k"            to cfg.k,
            "ef_runtime"   to cfg.ef,
            "truth_ms"     to (truthNs / 1_000_000L),
            "results"      to perAlgo,
        )
    }

    private fun runAlgo(
        cfg: Config,
        docVecs: Array<FloatArray>,
        queries: Array<FloatArray>,
        truthTopK: Array<IntArray>,
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
        Log.i(TAG, "    ingest ${cfg.nDocs}: ${ingestNs / 1_000_000L} ms")

        // Warm-up to prime the code path; discarded.
        val warm = minOf(20, queries.size)
        for (i in 0 until warm) idx.searchDirect(queries[i], cfg.k, efRuntime = cfg.ef)

        val lat = LongArray(cfg.nQueries)
        var hits = 0; var total = 0
        for (qi in 0 until cfg.nQueries) {
            val q = queries[qi]
            val t0 = System.nanoTime()
            val res = idx.searchDirect(q, cfg.k, efRuntime = cfg.ef)
            lat[qi] = (System.nanoTime() - t0) / 1_000L
            val got = HashSet<String>(res.size * 2)
            for ((id, _) in res) got.add(id)
            val truth = truthTopK[qi]
            for (t in truth) {
                val tid = "${a.prefix}:d${cfg.dim}n${cfg.nDocs}:$t"
                if (got.contains(tid)) hits++
                total++
            }
        }
        val recall = if (total > 0) hits.toDouble() / total else 0.0
        val stats = latencyStats(lat)
        Log.i(TAG, "    recall@${cfg.k}=${"%.4f".format(recall)}  p50=${stats["p50"]}µs  p95=${stats["p95"]}µs")

        return linkedMapOf(
            "ingest_total_ms" to (ingestNs / 1_000_000L),
            "ingest_avg_us"   to (ingestNs / 1_000.0 / cfg.nDocs),
            "recall_at_k"     to recall,
            "search_lat_us"   to stats,
        )
    }

    private fun runSqliteVectorAi(
        context: Context,
        cfg: Config,
        docVecs: Array<FloatArray>,
        queries: Array<FloatArray>,
        truthTopK: Array<IntArray>,
    ): Map<String, Any?> {
        // sqlite-vector uses raw cosine on stored vectors, so we pre-normalise
        // corpus and queries to match the (cosine) truth computed upstream.
        val docs = Array(cfg.nDocs) { docVecs[it].copyOf().also { v -> l2normalise(v) } }
        val qs   = Array(cfg.nQueries) { queries[it].copyOf().also { v -> l2normalise(v) } }

        val ids = Array(cfg.nDocs) { "sva:d${cfg.dim}n${cfg.nDocs}:$it" }
        val backend = SqliteVectorAiVector(context, cfg.dim, dbName = "vecsweep_sva_d${cfg.dim}")
        backend.create()

        val ingestStart = System.nanoTime()
        backend.addAll(ids, docs)
        val ingestNs = System.nanoTime() - ingestStart
        Log.i(TAG, "    ingest ${cfg.nDocs}: ${ingestNs / 1_000_000L} ms")

        // vector_quantize_scan requires a quantized snapshot; building it here
        // so the first search actually returns rows.
        val finalizeStart = System.nanoTime()
        backend.finalizeIndex()
        val finalizeNs = System.nanoTime() - finalizeStart
        Log.i(TAG, "    quantize: ${finalizeNs / 1_000_000L} ms")

        val warm = minOf(20, qs.size)
        for (i in 0 until warm) backend.search(qs[i], cfg.k)

        val lat = LongArray(cfg.nQueries)
        var hits = 0; var total = 0
        for (qi in 0 until cfg.nQueries) {
            val q = qs[qi]
            val t0 = System.nanoTime()
            val res = backend.search(q, cfg.k)
            lat[qi] = (System.nanoTime() - t0) / 1_000L
            val got = HashSet<String>(res.size * 2)
            for ((id, _) in res) got.add(id)
            val truth = truthTopK[qi]
            for (t in truth) {
                val tid = "sva:d${cfg.dim}n${cfg.nDocs}:$t"
                if (got.contains(tid)) hits++
                total++
            }
        }
        val recall = if (total > 0) hits.toDouble() / total else 0.0
        val stats = latencyStats(lat)
        Log.i(TAG, "    recall@${cfg.k}=${"%.4f".format(recall)}  p50=${stats["p50"]}µs  p95=${stats["p95"]}µs")

        val dbBytes = backend.dbFileSizeBytes()
        backend.close()

        return linkedMapOf(
            "ingest_total_ms"  to (ingestNs / 1_000_000L),
            "ingest_avg_us"    to (ingestNs / 1_000.0 / cfg.nDocs),
            "quantize_total_ms" to (finalizeNs / 1_000_000L),
            "recall_at_k"      to recall,
            "search_lat_us"    to stats,
            "db_file_bytes"    to dbBytes,
        )
    }

    private fun l2normalise(v: FloatArray) {
        var s = 0.0
        for (x in v) s += x.toDouble() * x
        val n = sqrt(s).toFloat()
        if (n <= 0f) return
        val inv = 1f / n
        for (i in v.indices) v[i] = v[i] * inv
    }

    /** Cosine top-k via a k-element max-heap on distance (1 - dot). */
    private fun topKIndices(docsNorm: Array<FloatArray>, q: FloatArray, k: Int): IntArray {
        val dim = q.size
        // Array-based binary heap keyed by distance, root = worst-in-top-k.
        val heapD = DoubleArray(k)
        val heapI = IntArray(k)
        var size = 0
        for (i in docsNorm.indices) {
            val d = docsNorm[i]
            var dot = 0.0
            for (j in 0 until dim) dot += d[j].toDouble() * q[j]
            val dist = 1.0 - dot
            if (size < k) {
                heapD[size] = dist; heapI[size] = i; size++
                if (size == k) buildMaxHeap(heapD, heapI)
            } else if (dist < heapD[0]) {
                heapD[0] = dist; heapI[0] = i
                siftDown(heapD, heapI, 0, k)
            }
        }
        // Sort ascending by distance for deterministic tie-break.
        val idx = IntArray(size) { it }
        // Simple insertion sort — k is small.
        for (i in 1 until size) {
            val kd = heapD[i]; val ki = heapI[i]
            var j = i - 1
            while (j >= 0 && heapD[j] > kd) { heapD[j+1] = heapD[j]; heapI[j+1] = heapI[j]; j-- }
            heapD[j+1] = kd; heapI[j+1] = ki
        }
        for (i in 0 until size) idx[i] = heapI[i]
        return idx
    }

    private fun buildMaxHeap(d: DoubleArray, idx: IntArray) {
        val n = d.size
        for (i in (n / 2 - 1) downTo 0) siftDown(d, idx, i, n)
    }

    private fun siftDown(d: DoubleArray, idx: IntArray, start: Int, n: Int) {
        var i = start
        while (true) {
            val l = 2 * i + 1; val r = 2 * i + 2
            var largest = i
            if (l < n && d[l] > d[largest]) largest = l
            if (r < n && d[r] > d[largest]) largest = r
            if (largest == i) return
            val td = d[i]; d[i] = d[largest]; d[largest] = td
            val ti = idx[i]; idx[i] = idx[largest]; idx[largest] = ti
            i = largest
        }
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
