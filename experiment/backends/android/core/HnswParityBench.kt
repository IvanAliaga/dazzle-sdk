// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

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
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.json.JSONObject

/**
 * Fase 1 closure (PIVOT_PLAN §4) — paridad on-device vs hnswlib x86.
 *
 * Reads the *exact same* binary dataset that `research/scripts/hnsw_parity.py`
 * wrote (seeded gaussian at dim=384, sizes N ∈ {1k, 10k, 100k}, 1000 held-out
 * queries, brute-force numpy ground truth for top-10), builds a dazzle-vector
 * HNSW index with M=16 / efConstruction=200, and sweeps ef_runtime ∈
 * {16, 32, 64, 128, 256, 512} reporting recall@10 + per-query latency per
 * (N, ef) cell.
 *
 * The same files are consumed by the x86 hnswlib run, so comparing the two
 * JSON outputs column-wise gives a bit-exact apples-to-apples parity check.
 * A |Δrecall| > 2 % at any cell flags a port bug in `valkeysearch_module.cc`.
 *
 * Expected push layout (push before launching — the files are 150 MB+, so
 * they don't belong inside the APK; we use the app-specific external dir
 * because shared /sdcard/Documents is not readable under scoped storage):
 *   adb push research/data/hnsw_parity/. \
 *     /storage/emulated/0/Android/data/dev.dazzle.experiment.backends/files/hnsw_parity/
 *
 * Invocation:
 *   adb shell am start -n dev.dazzle.experiment.backends/.BackendsActivity \
 *     --ez test_storage_only true --es backend hnsw-parity
 *
 * Output: /sdcard/Documents/hnsw_parity_<MODEL>_<TS>.json.
 */
object HnswParityBench {

    private const val TAG = "HnswParity"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val dataDir:        String = "hnsw_parity",
        val indexPrefix:    String = "par:",
        val efSweep:        IntArray = intArrayOf(16, 32, 64, 128, 256, 512),
        val m:              Int = 16,
        val efConstruction: Int = 200,
    )

    fun run(context: Context, cfg: Config = Config()) {
        try { runInner(context, cfg) }
        catch (t: Throwable) { Log.e(TAG, "bench failed", t); throw t }
    }

    private fun runInner(context: Context, cfg: Config) {
        Log.i(TAG, "══ HnswParityBench M=${cfg.m} efC=${cfg.efConstruction} ══")

        // App-specific external dir — accessible under Android 14 scoped
        // storage without MANAGE_EXTERNAL_STORAGE. adb push lands here too.
        val dataDir = File(
            context.getExternalFilesDir(null) ?: context.filesDir,
            cfg.dataDir,
        )
        check(dataDir.isDirectory) {
            "Expected dataset at ${dataDir.absolutePath}. Push first: " +
                "adb push research/data/hnsw_parity/. ${dataDir.absolutePath}/"
        }

        val manifest = JSONObject(File(dataDir, "manifest.json").readText())
        val dim = manifest.getInt("dim")
        val k   = manifest.getInt("k")
        val nQueries = manifest.getInt("n_queries")
        val sizesArr = manifest.getJSONArray("sizes")
        val sizes = IntArray(sizesArr.length()) { sizesArr.getInt(it) }
        Log.i(TAG, "manifest: dim=$dim k=$k nQueries=$nQueries sizes=${sizes.joinToString()}")

        val queries = readF32(File(dataDir, "queries.bin"))
        require(queries.rows == nQueries && queries.cols == dim) {
            "queries shape mismatch: got ${queries.rows}×${queries.cols}, expected $nQueries×$dim"
        }

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(context, DazzleConfig(
            port        = 6384,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)

        val out = linkedMapOf<String, Any?>(
            "type"      to "hnsw_parity",
            "timestamp" to java.time.Instant.now().toString(),
            "device"    to collectDeviceInfo(),
            "dim"       to dim,
            "m"         to cfg.m,
            "ef_construction" to cfg.efConstruction,
            "k"         to k,
            "n_queries" to nQueries,
            "ef_sweep"  to cfg.efSweep.toList(),
            "hnswlib_ref" to "valkey-search wrapped hnswlib v0.8.0",
            "per_n"     to linkedMapOf<String, Any?>(),
        )

        try {
            for (n in sizes) {
                Log.i(TAG, "── N=$n ──")
                @Suppress("UNCHECKED_CAST")
                (out["per_n"] as MutableMap<String, Any?>)[n.toString()] =
                    runOneN(cfg, dim, k, queries, dataDir, n)
            }
        } finally {
            try { DazzleServer.stop() } catch (_: Throwable) {}
        }

        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "hnsw_parity_${safeModel}_${ts}.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOCUMENTS,
            ).apply { mkdirs() }
            File(docs, fname)
        } catch (_: Exception) {
            File(context.filesDir, fname)
        }
        file.writeText(gson.toJson(out))
        Log.i(TAG, "══ wrote ${file.absolutePath} ══")
    }

    private fun runOneN(
        cfg: Config, dim: Int, k: Int, queries: Mat2D,
        dataDir: File, n: Int,
    ): Map<String, Any?> {
        val indexName = "parity_n$n"
        val prefix    = "${cfg.indexPrefix}n$n:"

        // Drop any leftover from a previous run on the same server instance.
        val client = DazzleServer.client()

        val index = client.vectorIndex(
            name            = indexName,
            hashPrefix      = prefix,
            vectorField     = "v",
            dim             = dim,
            algorithm       = VectorIndex.Algorithm.HNSW,
            metric          = VectorIndex.Metric.COSINE,
            initialCapacity = n,
            m               = cfg.m,
            efConstruction  = cfg.efConstruction,
        )
        index.create()

        // Read vectors + GT from disk.
        val vecs = readF32(File(dataDir, "vecs_n$n.bin"))
        require(vecs.rows == n && vecs.cols == dim) {
            "vecs_n$n shape mismatch: got ${vecs.rows}×${vecs.cols}"
        }
        val gt = readI32(File(dataDir, "gt_n${n}_k$k.bin"))
        require(gt.rows == queries.rows && gt.cols == k) {
            "gt shape mismatch: got ${gt.rows}×${gt.cols}, expected ${queries.rows}×$k"
        }

        // Batched insert — addBatchDirect expects Array<FloatArray>.
        val ids  = Array(n) { "$prefix$it" }
        val mat  = Array(n) { row ->
            FloatArray(dim).also { System.arraycopy(vecs.data, row * dim, it, 0, dim) }
        }
        val tBuild = System.nanoTime()
        index.addBatchDirect(ids, mat)
        val buildMs = (System.nanoTime() - tBuild) / 1_000_000L
        Log.i(TAG, "  indexed $n vectors in ${buildMs} ms")

        // ef sweep.
        val sweep = ArrayList<Map<String, Any?>>(cfg.efSweep.size)
        for (ef in cfg.efSweep) {
            val latUs = LongArray(queries.rows)
            var correct = 0
            val qv = FloatArray(dim)
            for (qi in 0 until queries.rows) {
                System.arraycopy(queries.data, qi * dim, qv, 0, dim)
                val t0 = System.nanoTime()
                val hits = index.searchDirect(qv, k = k, efRuntime = ef)
                latUs[qi] = (System.nanoTime() - t0) / 1_000L

                val gold = HashSet<Int>(k * 2)
                for (gj in 0 until k) gold += gt.data[qi * k + gj]

                for (h in hits) {
                    // id format: "<prefix><intIndex>" — strip prefix
                    val idInt = h.first.substringAfterLast(':').toIntOrNull() ?: continue
                    if (idInt in gold) correct++
                }
            }
            val recall = correct.toDouble() / (queries.rows * k)
            sweep += linkedMapOf(
                "ef" to ef,
                "recall_at_k" to recall,
                "latency_us" to latencyStats(latUs),
            )
            Log.i(TAG, "  ef=$ef recall@$k=${"%.4f".format(recall)} " +
                "p50=${latencyStats(latUs)["p50"]}µs p95=${latencyStats(latUs)["p95"]}µs")
        }

        try { index.drop() } catch (_: Throwable) {}

        return linkedMapOf(
            "build_ms" to buildMs,
            "sweep"    to sweep,
        )
    }

    // ── Binary IO ────────────────────────────────────────────────────────

    private data class Mat2D(val rows: Int, val cols: Int, val data: FloatArray)
    private data class IMat2D(val rows: Int, val cols: Int, val data: IntArray)

    private fun readF32(f: File): Mat2D {
        DataInputStream(FileInputStream(f)).use { s ->
            val rows = Integer.reverseBytes(s.readInt())
            val cols = Integer.reverseBytes(s.readInt())
            val total = rows * cols
            val buf = ByteBuffer.allocate(total * 4).order(ByteOrder.LITTLE_ENDIAN)
            val raw = ByteArray(total * 4)
            var read = 0
            while (read < raw.size) {
                val got = s.read(raw, read, raw.size - read)
                if (got < 0) error("short read on ${f.name} at $read / ${raw.size}")
                read += got
            }
            buf.put(raw).rewind()
            val out = FloatArray(total)
            buf.asFloatBuffer().get(out)
            return Mat2D(rows, cols, out)
        }
    }

    private fun readI32(f: File): IMat2D {
        DataInputStream(FileInputStream(f)).use { s ->
            val rows = Integer.reverseBytes(s.readInt())
            val cols = Integer.reverseBytes(s.readInt())
            val total = rows * cols
            val buf = ByteBuffer.allocate(total * 4).order(ByteOrder.LITTLE_ENDIAN)
            val raw = ByteArray(total * 4)
            var read = 0
            while (read < raw.size) {
                val got = s.read(raw, read, raw.size - read)
                if (got < 0) error("short read on ${f.name} at $read / ${raw.size}")
                read += got
            }
            buf.put(raw).rewind()
            val out = IntArray(total)
            buf.asIntBuffer().get(out)
            return IMat2D(rows, cols, out)
        }
    }

    // ── Stats ────────────────────────────────────────────────────────────

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
