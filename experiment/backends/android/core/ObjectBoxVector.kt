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
import dev.dazzle.experiment.objectbox.MyObjectBox
import dev.dazzle.experiment.objectbox.VectorEntity
import dev.dazzle.experiment.objectbox.VectorEntity_
import io.objectbox.BoxStore
import io.objectbox.kotlin.boxFor
import java.io.File

/**
 * ObjectBox-vector backend for the vector-search benchmark.
 *
 * ObjectBox 4.0+ ships on-device HNSW via [io.objectbox.annotation.HnswIndex].
 * The entity [VectorEntity] is compiled with `dimensions = 384`; shorter
 * vectors are zero-padded at ingest time. Zero-padding is invisible to cosine
 * similarity after L2 normalisation, so recall numbers remain apples-to-apples
 * across dims.
 *
 * This backend exposes the same surface (create/add/addAll/search) as
 * [SqliteBruteforceVector] and the Dazzle [dev.dazzle.sdk.VectorIndex], so
 * [VectorBenchmark] can drive them all through one helper.
 */
class ObjectBoxVectorBackend(
    private val context: Context,
    private val dim: Int,
    private val dbName: String = "vecbench_objectbox",
) {
    companion object {
        /** Must match [VectorEntity.embedding]'s @HnswIndex(dimensions=...) */
        const val STORED_DIM: Int = 384
    }

    private lateinit var store: BoxStore
    private lateinit var box: io.objectbox.Box<VectorEntity>

    fun create() {
        require(dim <= STORED_DIM) {
            "ObjectBox VectorEntity is compiled with dim=$STORED_DIM; " +
                    "requested dim=$dim exceeds it"
        }
        val dir = File(context.filesDir, dbName)
        if (dir.exists()) dir.deleteRecursively()
        store = MyObjectBox.builder()
            .androidContext(context.applicationContext)
            .name(dbName)
            .build()
        box = store.boxFor()
        box.removeAll()
    }

    fun close() {
        if (::store.isInitialized) store.close()
    }

    private fun padAndNormalise(v: FloatArray): FloatArray {
        val out = FloatArray(STORED_DIM)
        var s = 0f
        for (x in v) s += x * x
        if (s < 1e-12f) return out
        val inv = 1f / kotlin.math.sqrt(s)
        for (i in v.indices) out[i] = v[i] * inv
        // remaining tail is already 0f
        return out
    }

    fun add(id: String, vector: FloatArray) {
        require(vector.size == dim)
        box.put(VectorEntity(externalId = id, embedding = padAndNormalise(vector)))
    }

    /** Bulk ingest inside a single ObjectBox transaction. */
    fun addAll(ids: Array<String>, vectors: Array<FloatArray>) {
        require(ids.size == vectors.size)
        val entities = ArrayList<VectorEntity>(ids.size)
        for (i in ids.indices) {
            entities += VectorEntity(
                externalId = ids[i],
                embedding = padAndNormalise(vectors[i]),
            )
        }
        box.put(entities)
    }

    /**
     * HNSW nearest neighbours via ObjectBox's native vector query.
     * Returns (externalId, score) sorted by ascending distance (closest first).
     *
     * [ef] maps to ObjectBox's search-time ef via `setVectorSearchQueryParam`
     * if the installed version supports it; otherwise it's ignored and the
     * index default is used.
     */
    fun search(query: FloatArray, k: Int, ef: Int = 0): List<Pair<String, Float>> {
        require(query.size == dim)
        val q = padAndNormalise(query)
        val builder = box.query(VectorEntity_.embedding.nearestNeighbors(q, k))
        // ObjectBox 4.x/5.x exposes no public knob for ef at query time — the
        // HNSW index's neighborsSearchCount is set at build time via the
        // annotation. [ef] is accepted for API parity with other backends.
        val built = builder.build()
        return try {
            val pairs = built.findWithScores()
            pairs.map { it.get().externalId to it.score.toFloat() }
        } finally {
            built.close()
        }
    }

    fun count(): Long = box.count()

    fun dbSizeBytes(): Long {
        val dir = File(context.filesDir, dbName)
        if (!dir.exists()) return -1L
        var total = 0L
        dir.walkTopDown().forEach { if (it.isFile) total += it.length() }
        return total
    }
}
