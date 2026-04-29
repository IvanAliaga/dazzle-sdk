// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package dev.dazzle.experiment

import android.content.Context
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * sqlite-vec backend for the vector-search benchmark.
 *
 * Uses a statically-linked SQLite 3.50 + sqlite-vec 0.1.9 via [libsqlitevec-jni.so].
 * Vectors go into a `vec0` virtual table with `distance_metric=cosine`. Queries
 * are plain SQL: `WHERE embedding MATCH ? AND k = ? ORDER BY distance`.
 *
 * sqlite-vec's vec0 is a brute-force index (not HNSW) — recall is always
 * exact, so `recall@k == 1.0` by construction. What we're measuring here is
 * whether sqlite-vec's tight C loop beats dazzle-vector's HNSW on latency
 * once N gets large (which, for exact search, it should not).
 */
class SqliteVecVector(
    private val context: Context,
    private val dim: Int,
    private val dbName: String = "vecbench_sqlitevec",
    private val normalizeOnAccess: Boolean = true,
) {

    private var handle: Long = 0

    fun create() {
        val file = File(context.filesDir, "$dbName.db")
        if (file.exists()) file.delete()
        // Ancillary files WAL/SHM also need to go.
        File(context.filesDir, "$dbName.db-wal").delete()
        File(context.filesDir, "$dbName.db-shm").delete()
        handle = nOpen(file.absolutePath, dim)
        check(handle != 0L) { "sqlite-vec open failed — see logcat SqliteVecJNI" }
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

    private fun normalise(v: FloatArray): FloatArray {
        var s = 0f
        for (x in v) s += x * x
        if (s < 1e-12f) return v
        val inv = 1f / kotlin.math.sqrt(s)
        val out = FloatArray(v.size)
        for (i in v.indices) out[i] = v[i] * inv
        return out
    }

    fun add(id: String, vector: FloatArray) {
        require(vector.size == dim)
        val v = if (normalizeOnAccess) normalise(vector) else vector
        nAdd(handle, id, vecToDirect(v))
    }

    /** Bulk ingest wrapped in a single SQLite transaction. */
    fun addAll(ids: Array<String>, vectors: Array<FloatArray>) {
        require(ids.size == vectors.size)
        nBeginTx(handle)
        try {
            for (i in ids.indices) {
                val v = if (normalizeOnAccess) normalise(vectors[i]) else vectors[i]
                nAdd(handle, ids[i], vecToDirect(v))
            }
            nCommitTx(handle)
        } catch (t: Throwable) {
            // On failure we still try to close the transaction — ROLLBACK
            // would be cleaner but the benchmark aborts on any add failure.
            nCommitTx(handle)
            throw t
        }
    }

    /** k-NN search. Returns (id, score) sorted by ascending distance. */
    fun search(query: FloatArray, k: Int): List<Pair<String, Float>> {
        require(query.size == dim)
        val q = if (normalizeOnAccess) normalise(query) else query
        val arr = nKnn(handle, vecToDirect(q), k) ?: return emptyList()
        val out = ArrayList<Pair<String, Float>>(arr.size / 2)
        var i = 0
        while (i + 1 < arr.size) {
            val id = arr[i] ?: break
            val score = arr[i + 1]?.toFloatOrNull() ?: Float.MAX_VALUE
            out += id to score
            i += 2
        }
        return out
    }

    fun count(): Long = nCount(handle)

    fun dbFileSizeBytes(): Long {
        val f = File(context.filesDir, "$dbName.db")
        return if (f.exists()) f.length() else -1L
    }

    companion object {
        init { System.loadLibrary("sqlitevec-jni") }

        @JvmStatic private external fun nOpen(path: String, dim: Int): Long
        @JvmStatic private external fun nClose(handle: Long)
        @JvmStatic private external fun nBeginTx(handle: Long)
        @JvmStatic private external fun nCommitTx(handle: Long)
        @JvmStatic private external fun nAdd(handle: Long, id: String, vec: ByteBuffer)
        @JvmStatic private external fun nKnn(handle: Long, query: ByteBuffer, k: Int): Array<String?>?
        @JvmStatic private external fun nCount(handle: Long): Long
    }
}
