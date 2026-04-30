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

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * SQLite brute-force k-NN baseline for the vector-search benchmark.
 *
 * Uses stock Android SQLite (no extensions — sqlite-vec is a stretch goal in
 * a separate wrapper). Stores L2-normalised FLOAT32 vectors as a BLOB column
 * and scans every row on each query, computing inner product (= cosine when
 * both vectors are normalised) in Kotlin.
 *
 * Rationale: this is the realistic fallback a mobile developer reaches for
 * when they do not want to ship a native HNSW module — the apples-to-apples
 * baseline we need to beat. As a side effect, brute-force also serves as the
 * ground truth for recall@k measurement on HNSW.
 *
 * Storage layout: one row per vector,
 *   id       TEXT PRIMARY KEY,
 *   embedding BLOB NOT NULL    // dim * 4 bytes, little-endian, L2-normalised
 *
 * The database file lives under `context.filesDir/<dbName>.db` and is wiped
 * at [create] time so each benchmark run starts from empty.
 */
class SqliteBruteforceVector(
    private val context: Context,
    private val dim: Int,
    private val dbName: String = "vecbench_sqlite_bf",
) {

    private lateinit var db: SQLiteDatabase

    fun create() {
        // SQLiteOpenHelper writes to `<dataDir>/databases/`, NOT to
        // `<filesDir>` — the previous file delete in this method aimed
        // at the wrong directory and therefore never wiped the file
        // between configs (or between bench-app launches). The
        // accumulated docs caused the brute-force *truth source* to
        // scan thousands of stale rows, producing a recall mismatch
        // against engines that only index the current config's docs
        // (the well-known 0.111 / 0.146 / 0.317 / 1.0 pattern in early
        // VectorBenchmark runs). Use the SDK-provided path here, and
        // also DELETE FROM vecs after open as a belt-and-suspenders
        // guard against any leftover rows the file delete missed.
        val main = context.getDatabasePath("$dbName.db")
        if (main.exists()) {
            main.delete()
            File(main.path + "-wal").delete()
            File(main.path + "-shm").delete()
            File(main.path + "-journal").delete()
        }
        val helper = object : SQLiteOpenHelper(context, "$dbName.db", null, 1) {
            override fun onCreate(d: SQLiteDatabase) {
                d.execSQL(
                    "CREATE TABLE vecs (id TEXT PRIMARY KEY, embedding BLOB NOT NULL)"
                )
            }
            override fun onUpgrade(d: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}
        }
        db = helper.writableDatabase
        // Belt-and-suspenders truncate: if onCreate didn't fire because
        // a previous file slipped past the delete, this still leaves
        // the table empty for a clean ingest.
        runCatching { db.execSQL("DELETE FROM vecs") }
        // Tuning knobs a mobile dev would reasonably flip: WAL + sync=NORMAL.
        // This gives SQLite its best-case write path so the comparison is fair.
        // Android throws on execSQL for PRAGMAs that return rows — use rawQuery.
        db.rawQuery("PRAGMA journal_mode=WAL", null).use { it.moveToFirst() }
        db.rawQuery("PRAGMA synchronous=NORMAL", null).use { it.moveToFirst() }
    }

    fun close() {
        if (::db.isInitialized) db.close()
    }

    /** Insert one vector. [vector] is L2-normalised in place. */
    fun add(id: String, vector: FloatArray) {
        require(vector.size == dim)
        normaliseInPlace(vector)
        val buf = ByteBuffer.allocate(dim * 4).order(ByteOrder.LITTLE_ENDIAN)
        vector.forEach { buf.putFloat(it) }
        val cv = ContentValues().apply {
            put("id", id)
            put("embedding", buf.array())
        }
        db.insertWithOnConflict("vecs", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
    }

    /**
     * Bulk ingest inside a single transaction — this is the realistic hot path
     * for mobile developers. Without BEGIN/COMMIT, SQLite fsyncs per row.
     */
    fun addAll(ids: Array<String>, vectors: Array<FloatArray>) {
        require(ids.size == vectors.size)
        db.beginTransaction()
        try {
            val stmt = db.compileStatement("INSERT OR REPLACE INTO vecs (id, embedding) VALUES (?, ?)")
            for (i in ids.indices) {
                val v = vectors[i]
                normaliseInPlace(v)
                val buf = ByteBuffer.allocate(dim * 4).order(ByteOrder.LITTLE_ENDIAN)
                v.forEach { buf.putFloat(it) }
                stmt.clearBindings()
                stmt.bindString(1, ids[i])
                stmt.bindBlob(2, buf.array())
                stmt.executeInsert()
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /**
     * Brute-force top-k by cosine similarity (stored vectors are already
     * normalised, so inner product == cosine). Returns ids sorted by
     * descending similarity (closest first) with their score.
     */
    fun search(query: FloatArray, k: Int): List<Pair<String, Float>> {
        require(query.size == dim)
        val q = query.copyOf()
        normaliseInPlace(q)

        // Pull every row. For the benchmark sizes we care about (up to ~10k × 384)
        // this fits comfortably in memory and matches what a mobile dev would
        // actually write. Any streaming approach would only be slower.
        val cursor = db.rawQuery("SELECT id, embedding FROM vecs", null)
        // Keep the top-k in a simple array; for k≪N a min-heap would help, but
        // k is small (≤100) and the inner loop is dominated by the dot product.
        val topIds = arrayOfNulls<String>(k)
        val topScores = FloatArray(k) { Float.NEGATIVE_INFINITY }

        try {
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                val blob = cursor.getBlob(1)
                if (blob.size != dim * 4) {
                    // Defensive: skip rows whose stored dim doesn't match the
                    // requested one. Happens if an older DB file survived a
                    // schema change despite the onCreate delete — shouldn't
                    // happen in practice but cheap to guard.
                    continue
                }
                // Read `dim` little-endian floats from the blob WITHOUT a shared
                // ByteBuffer. The previous ByteBuffer-based path threw
                // BufferUnderflowException on dim≥128; decoding directly from
                // the byte[] is also measurably faster.
                var dot = 0f
                var off = 0
                for (i in 0 until dim) {
                    val b0 = blob[off].toInt() and 0xFF
                    val b1 = blob[off + 1].toInt() and 0xFF
                    val b2 = blob[off + 2].toInt() and 0xFF
                    val b3 = blob[off + 3].toInt() and 0xFF
                    val bits = b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
                    dot += q[i] * java.lang.Float.intBitsToFloat(bits)
                    off += 4
                }
                // Insert into top-k if it beats the smallest kept score.
                var minIdx = 0
                for (j in 1 until k) if (topScores[j] < topScores[minIdx]) minIdx = j
                if (dot > topScores[minIdx]) {
                    topScores[minIdx] = dot
                    topIds[minIdx] = id
                }
            }
        } finally {
            cursor.close()
        }

        val pairs = mutableListOf<Pair<String, Float>>()
        for (j in 0 until k) {
            val id = topIds[j] ?: continue
            pairs += id to topScores[j]
        }
        pairs.sortByDescending { it.second }
        return pairs
    }

    fun count(): Long {
        val c = db.rawQuery("SELECT COUNT(*) FROM vecs", null)
        return c.use { if (it.moveToNext()) it.getLong(0) else 0L }
    }

    fun dbFileSizeBytes(): Long {
        // SQLiteOpenHelper places the DB under `<dataDir>/databases/`, NOT
        // `<filesDir>` — the previous lookup hit the wrong directory and
        // returned -1, which surfaced as "not reported" in Table 11.
        // Sum the main `.db` plus its WAL / SHM / journal sidecars to
        // match what the user would actually see on disk.
        val main = context.getDatabasePath("$dbName.db")
        if (!main.exists()) return -1L
        val parent = main.parentFile ?: return main.length()
        var total = 0L
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            val f = File(parent, "${main.name}$suffix")
            if (f.exists()) total += f.length()
        }
        return total
    }

    companion object {
        internal fun normaliseInPlace(v: FloatArray) {
            var s = 0f
            for (x in v) s += x * x
            if (s < 1e-12f) return
            val inv = 1f / kotlin.math.sqrt(s)
            for (i in v.indices) v[i] *= inv
        }
    }
}
