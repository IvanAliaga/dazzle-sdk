// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.content.Context
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * SQLiteAI `sqlite-vector` backend for the vector-search benchmark.
 *
 * Statically-linked SQLite 3.x + `libvector.so` (ai.sqlite:vector:0.9.80,
 * extracted from the public Maven AAR at build time and placed in
 * jniLibs/arm64-v8a/). The extension is Elastic License 2.0 — bench-only.
 *
 * Table layout: `emb(id INTEGER PRIMARY KEY, vector BLOB)`. String document
 * ids come in from the test harness; we map them 1:1 to the int rowid by
 * keeping a parallel ArrayList<String>, so the harness's recall comparison
 * still sees the same id space the other backends return.
 *
 * Search is brute-force SIMD (sqlite-vector ships no ANN index by default);
 * recall is always 1.0 by construction, so what the bench really measures
 * here is per-query scan wall-time vs dazzle-vector's HNSW.
 */
class SqliteVectorAiVector(
    private val context: Context,
    private val dim: Int,
    private val dbName: String = "vecbench_sqlvectorai",
) {

    private var handle: Long = 0
    private val idToRowid = HashMap<String, Long>()
    private val rowidToId = ArrayList<String>()

    fun create() {
        val file = File(context.filesDir, "$dbName.db")
        if (file.exists()) file.delete()
        File(context.filesDir, "$dbName.db-wal").delete()
        File(context.filesDir, "$dbName.db-shm").delete()
        idToRowid.clear()
        rowidToId.clear()
        handle = nOpen(file.absolutePath, dim)
        check(handle != 0L) { "sqlite-vector open failed — see logcat SqliteVectorAIJNI" }
    }

    fun close() {
        if (handle != 0L) { nClose(handle); handle = 0 }
    }

    private fun vecToDirect(v: FloatArray): ByteBuffer {
        val buf = ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        buf.asFloatBuffer().put(v)
        buf.position(0)
        return buf
    }

    fun add(id: String, vector: FloatArray) {
        require(vector.size == dim)
        val rowid = rowidToId.size.toLong() + 1L  // SQLite rowid is 1-indexed
        nAdd(handle, rowid, vecToDirect(vector))
        idToRowid[id] = rowid
        rowidToId += id
    }

    /** Bulk ingest wrapped in a single SQLite transaction. */
    fun addAll(ids: Array<String>, vectors: Array<FloatArray>) {
        require(ids.size == vectors.size)
        nBeginTx(handle)
        try {
            for (i in ids.indices) {
                val rowid = rowidToId.size.toLong() + 1L
                nAdd(handle, rowid, vecToDirect(vectors[i]))
                idToRowid[ids[i]] = rowid
                rowidToId += ids[i]
            }
            nCommitTx(handle)
        } catch (t: Throwable) {
            nCommitTx(handle)
            throw t
        }
    }

    /** k-NN search. Returns (id, distance) sorted by ascending distance. */
    fun search(query: FloatArray, k: Int): List<Pair<String, Float>> {
        require(query.size == dim)
        @Suppress("UNCHECKED_CAST")
        val pair = nKnn(handle, vecToDirect(query), k) ?: return emptyList()
        val ids   = pair[0] as LongArray
        val dists = pair[1] as FloatArray
        val out = ArrayList<Pair<String, Float>>(ids.size)
        for (i in ids.indices) {
            val rowid = ids[i]
            val idx = (rowid - 1L).toInt()
            if (idx in rowidToId.indices) out += rowidToId[idx] to dists[i]
        }
        return out
    }

    /**
     * Build the quantized snapshot over `emb.vector`. Must be called after
     * `addAll` / the last `add`, before the first `search`. Without it,
     * `vector_quantize_scan` returns zero rows (observed: recall=0).
     */
    fun finalizeIndex(maxMemoryMb: Int = 50, preload: Boolean = true) {
        val rc = nFinalizeIndex(handle, maxMemoryMb, preload)
        check(rc == 0) { "vector_quantize failed rc=$rc — see logcat SqliteVectorAIJNI" }
    }

    fun count(): Long = nCount(handle)

    fun dbFileSizeBytes(): Long {
        val f = File(context.filesDir, "$dbName.db")
        return if (f.exists()) f.length() else -1L
    }

    companion object {
        init {
            // libvector.so must be loaded first so its symbols are resolvable
            // when sqlite3_load_extension(dlopen) fires inside nOpen.
            try { System.loadLibrary("vector") } catch (_: UnsatisfiedLinkError) {}
            System.loadLibrary("sqlitevectorai-jni")
        }

        @JvmStatic private external fun nOpen(path: String, dim: Int): Long
        @JvmStatic private external fun nClose(handle: Long)
        @JvmStatic private external fun nBeginTx(handle: Long)
        @JvmStatic private external fun nCommitTx(handle: Long)
        @JvmStatic private external fun nAdd(handle: Long, id: Long, vec: ByteBuffer)
        @JvmStatic private external fun nKnn(handle: Long, query: ByteBuffer, k: Int): Array<Any>?
        @JvmStatic private external fun nFinalizeIndex(
            handle: Long,
            maxMemoryMb: Int,
            preload: Boolean,
        ): Int
        @JvmStatic private external fun nCount(handle: Long): Long
    }
}
