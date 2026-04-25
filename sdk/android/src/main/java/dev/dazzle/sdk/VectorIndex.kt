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

package dev.dazzle.sdk

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Type-safe wrapper around a valkey-search vector index.
 *
 * Requires [DazzleModule.VectorSearch] in [DazzleConfig.modules] at server
 * start. Uses FT.CREATE / FT.SEARCH / HSET; all vectors are stored as raw
 * FLOAT32 blobs in a hash field under the given [hashPrefix].
 *
 * ```kotlin
 * DazzleServer.start(context, DazzleConfig(
 *     modules = setOf(DazzleModule.VectorSearch)
 * ))
 *
 * val index = dazzle.vectorIndex(
 *     name        = "docs",
 *     hashPrefix  = "doc:",
 *     vectorField = "embedding",
 *     dim         = 384,
 * )
 * index.create()
 * index.add("doc:1", floatArrayOf(...), mapOf("text" to "hello world"))
 * val results = index.search(queryVector, k = 5)
 * ```
 */
class VectorIndex internal constructor(
    private val server: DazzleServer,
    val name: String,
    val hashPrefix: String,
    val vectorField: String,
    val dim: Int,
    val algorithm: Algorithm = Algorithm.HNSW,
    val metric: Metric = Metric.COSINE,
    /**
     * Pre-allocated capacity for the HNSW graph (and companion label/map/
     * fp32 buffers). When the final corpus size is known up front, setting
     * this avoids every mid-traffic `resizeIndex` event — each of those
     * takes the one exclusive write lock readers do fence on. 0 means
     * "library default" (currently 1024, doubles on demand).
     */
    val initialCapacity: Int = 0,
    /**
     * HNSW graph degree (max number of outgoing links per node in the base
     * layer; upper layers use M/2). Higher = higher recall, more memory,
     * slower inserts. 0 = library default (32).
     */
    val m: Int = 0,
    /**
     * HNSW build-time candidate-list width. Sets the quality/cost of the
     * graph the index builds as you insert. Lower = faster inserts (the
     * writer's time inside hnswlib's internal per-link locks shrinks
     * proportionally) at a small recall cost. 0 = library default (400).
     * Only affects insert quality; query-time accuracy is controlled by
     * the per-call `efRuntime` parameter on search.
     */
    val efConstruction: Int = 0,
) {

    enum class Algorithm { FLAT, HNSW, HNSW_SQ8, HNSW_SQ8_RERANK, HNSW_F16 }
    enum class Metric    { COSINE, L2, IP }

    data class SearchResult(
        val id: String,
        val score: Float,
        val fields: Map<String, String>,
    )

    companion object {
        init {
            // libdazzle.so is loaded by DazzleServer.init; the valkey-search
            // module (and its JNI exports nAddDirect / nSearchDirect) ships
            // inside it via the static-link path. Fall through silently when
            // called from a build that still had a separate libvalkeysearch.so.
            try { System.loadLibrary("dazzle") } catch (_: UnsatisfiedLinkError) {}
        }

        @JvmStatic external fun nAddDirect(indexName: String, key: String, vec: java.nio.ByteBuffer)
        @JvmStatic external fun nAddBatchDirect(
            indexName: String, ids: Array<String>, vecs: java.nio.ByteBuffer, nVecs: Int,
        )
        @JvmStatic external fun nSearchDirect(
            indexName: String, query: java.nio.ByteBuffer, k: Int, efRuntime: Int,
        ): Array<String>
        @JvmStatic external fun nOpenHandle(indexName: String): Long
        @JvmStatic external fun nCreateSq8(indexName: String, dim: Int, M: Int, efC: Int, initialCap: Int): Long
        @JvmStatic external fun nCreateSq8Rerank(indexName: String, dim: Int, M: Int, efC: Int, initialCap: Int): Long
        @JvmStatic external fun nCreateF16(indexName: String, dim: Int, M: Int, efC: Int, initialCap: Int): Long
        @JvmStatic external fun nSearchHandle(
            handle: Long, query: java.nio.ByteBuffer, k: Int, efRuntime: Int,
        ): Array<Any>
    }

    private fun FloatArray.toDirectBuffer(): java.nio.ByteBuffer {
        val buf = java.nio.ByteBuffer.allocateDirect(size * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        val fb = buf.asFloatBuffer()
        fb.put(this)
        return buf
    }

    /**
     * Fast-path add: stores the vector directly in the HNSW index via JNI,
     * bypassing FT.HADD/RESP/base64. The key is NOT stored as a Valkey hash
     * — use [add] if you also need hash metadata. Intended for hot loops
     * (benchmarks, bulk import). Requires the index to exist ([create]).
     */
    fun addDirect(id: String, vector: FloatArray) {
        require(vector.size == dim) { "vector has ${vector.size} dims, index expects $dim" }
        nAddDirect(name, id, vector.toDirectBuffer())
    }

    /**
     * Bulk fast-path add: one JNI round-trip for [n] vectors laid out
     * contiguously as FLOAT32 little-endian in [packed] (n × dim floats).
     * Intended for initial corpus import where the JNI boundary cost
     * otherwise dominates per-vector.
     */
    fun addBatchDirect(ids: Array<String>, vectors: Array<FloatArray>) {
        require(ids.size == vectors.size)
        val n = ids.size
        if (n == 0) return
        val buf = java.nio.ByteBuffer.allocateDirect(n * dim * 4)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
        val fb = buf.asFloatBuffer()
        for (v in vectors) {
            require(v.size == dim) { "vector size ${v.size} != $dim" }
            fb.put(v)
        }
        nAddBatchDirect(name, ids, buf, n)
    }

    /**
     * Fast-path search: runs HNSW KNN directly via JNI, returning
     * (id, distance) pairs sorted by ascending distance. No RESP encoding,
     * no base64 — the query vector crosses as a direct FLOAT32 ByteBuffer.
     *
     * Uses an opaque schema handle cached after [create] so the hot path
     * skips the name→schema hash lookup on [g_indexes] (a per-process
     * mutex + unordered_map lookup on every call). Distances come back as
     * a parallel [FloatArray] instead of being formatted via `%.9g` and
     * round-tripped as strings.
     */
    fun searchDirect(query: FloatArray, k: Int = 10, efRuntime: Int = 0): List<Pair<String, Float>> {
        require(query.size == dim) { "query has ${query.size} dims, index expects $dim" }
        var h = handle
        if (h == 0L) {
            h = nOpenHandle(name)
            handle = h
        }
        if (h == 0L) return emptyList()  // index not created yet
        @Suppress("UNCHECKED_CAST")
        val pair = nSearchHandle(h, query.toDirectBuffer(), k, efRuntime)
        val ids = pair[0] as Array<String>
        val dists = pair[1] as FloatArray
        val out = ArrayList<Pair<String, Float>>(ids.size)
        for (i in ids.indices) out += ids[i] to dists[i]
        return out
    }

    @Volatile private var handle: Long = 0L

    /**
     * FT.CREATE — create the index. Safe to call repeatedly; returns false if
     * the index already exists (valkey-search replies with ERR Index already exists).
     */
    fun create(): Boolean {
        // 0 → library default. Kept as sentinel so callers don't need to
        // know the current defaults (32 / 400) — the native side resolves.
        val mArg  = if (m > 0) m else 32
        val efArg = if (efConstruction > 0) efConstruction else 400
        if (algorithm == Algorithm.HNSW_F16) {
            require(metric == Metric.COSINE) { "HNSW_F16 only supports Metric.COSINE" }
            val h = nCreateF16(name, dim, mArg, efArg, initialCapacity)
            handle = h
            return h != 0L
        }
        if (algorithm == Algorithm.HNSW_SQ8 || algorithm == Algorithm.HNSW_SQ8_RERANK) {
            // SQ8 bypasses FT.CREATE — the schema lives entirely inside
            // libvalkeysearch (int8 storage + NEON SDOT distance). Only
            // COSINE is supported: cosine is scale-invariant so per-vector
            // quantisation needs no stored scale.
            require(metric == Metric.COSINE) {
                "$algorithm only supports Metric.COSINE"
            }
            val h = if (algorithm == Algorithm.HNSW_SQ8_RERANK) {
                nCreateSq8Rerank(name, dim, mArg, efArg, initialCapacity)
            } else {
                nCreateSq8(name, dim, mArg, efArg, initialCapacity)
            }
            handle = h
            return h != 0L
        }
        val algoStr = algorithm.name
        val metricStr = metric.name

        // FLAT index: 6 params (TYPE, DIM, DISTANCE_METRIC)
        // HNSW index: 6 params same (valkey-search uses same schema for both)
        val baseArgs = mutableListOf(
            "FT.CREATE", name,
            "ON", "HASH",
            "PREFIX", "1", hashPrefix,
            "SCHEMA",
            vectorField, "VECTOR", algoStr,
            "6",
            "TYPE", "FLOAT32",
            "DIM", dim.toString(),
            "DISTANCE_METRIC", metricStr,
        )
        if (initialCapacity > 0) {
            baseArgs += "INITIAL_CAP"
            baseArgs += initialCapacity.toString()
        }
        if (m > 0) {
            baseArgs += "M"
            baseArgs += m.toString()
        }
        if (efConstruction > 0) {
            baseArgs += "EF_CONSTRUCTION"
            baseArgs += efConstruction.toString()
        }
        return try {
            server.commandTyped(*baseArgs.toTypedArray())
            true
        } catch (e: DazzleException.CommandFailed) {
            // "Index already exists" is not a fatal error
            !e.message.orEmpty().contains("already exists", ignoreCase = true)
        }
    }

    /**
     * FT.DROPINDEX — drop the index (does NOT delete the underlying hashes).
     */
    fun drop(): Boolean = try {
        server.commandTyped("FT.DROPINDEX", name)
        true
    } catch (_: DazzleException.CommandFailed) { false }

    /**
     * Store a vector + optional metadata fields under [id].
     * [id] must start with [hashPrefix] (e.g. "doc:42").
     * [vector] must have exactly [dim] elements.
     */
    fun add(id: String, vector: FloatArray, metadata: Map<String, String> = emptyMap()) {
        require(vector.size == dim) {
            "vector has ${vector.size} dims, index expects $dim"
        }
        val blob = vector.toBlob()
        // FT.HADD: synchronous HSET + index in the module (avoids keyspace
        // notification requirement and binary encoding issues).
        val args = mutableListOf("FT.HADD", name, id, vectorField, blob)
        for ((k, v) in metadata) { args += k; args += v }
        server.directCommand(*args.toTypedArray())
    }

    /**
     * FT.SEARCH KNN — find the [k] nearest neighbours to [query].
     *
     * Returns results sorted by ascending distance (score = 0 is identical).
     * Each [SearchResult.fields] contains the hash fields returned by the
     * server (excluding the raw vector blob).
     *
     * @param returnFields specific hash fields to include in results;
     *        empty means return all non-vector fields.
     */
    fun search(
        query: FloatArray,
        k: Int = 10,
        returnFields: List<String> = emptyList(),
        efRuntime: Int = 0,
    ): List<SearchResult> {
        require(query.size == dim) {
            "query has ${query.size} dims, index expects $dim"
        }
        val blob = query.toBlob()
        val scoreAlias = "__${vectorField}_score"

        // EF_RUNTIME: optional HNSW search-time ef. Higher = better recall,
        // higher latency. Passed through PARAMS so it survives the existing
        // argv layout; ignored by the server if 0.
        val paramsCount = if (efRuntime > 0) 4 else 2
        val args = mutableListOf(
            "FT.SEARCH", name,
            "*=>[KNN $k @$vectorField \$BLOB AS $scoreAlias]",
            "PARAMS", paramsCount.toString(), "BLOB", blob,
        )
        if (efRuntime > 0) {
            args += "EF_RUNTIME"
            args += efRuntime.toString()
        }
        args += "SORTBY"
        args += scoreAlias
        args += "DIALECT"
        args += "2"
        if (returnFields.isNotEmpty()) {
            args += "RETURN"
            args += (returnFields.size + 1).toString()
            args += scoreAlias
            args.addAll(returnFields)
        }

        return try {
            val resp = server.commandTyped(*args.toTypedArray())
            parseSearchResults(resp, scoreAlias)
        } catch (_: DazzleException.CommandFailed) { emptyList() }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun FloatArray.toBlob(): String {
        val buf = ByteBuffer.allocate(size * 4).order(ByteOrder.LITTLE_ENDIAN)
        forEach { buf.putFloat(it) }
        // Base64-encode so the blob survives JNI UTF-8 string marshalling
        // (bytes > 0x7F would be corrupted by GetStringUTFChars otherwise).
        return Base64.encodeToString(buf.array(), Base64.NO_WRAP)
    }

    private fun parseSearchResults(resp: RespValue, scoreAlias: String): List<SearchResult> {
        val arr = (resp as? RespValue.Array)?.items ?: return emptyList()
        // FT.SEARCH reply: [total_count, id1, [field1, val1, ...], id2, ...]
        if (arr.size < 2) return emptyList()
        val results = mutableListOf<SearchResult>()
        var i = 1
        while (i + 1 < arr.size) {
            val id = (arr[i] as? RespValue.Bulk)?.value ?: run { i += 2; continue }
            val fieldArr = (arr[i + 1] as? RespValue.Array)?.items ?: run { i += 2; continue }
            val fields = mutableMapOf<String, String>()
            var j = 0
            while (j + 1 < fieldArr.size) {
                val fk = (fieldArr[j] as? RespValue.Bulk)?.value ?: run { j += 2; continue }
                val fv = (fieldArr[j + 1] as? RespValue.Bulk)?.value ?: ""
                fields[fk] = fv
                j += 2
            }
            val score = fields.remove(scoreAlias)?.toFloatOrNull() ?: Float.MAX_VALUE
            results += SearchResult(id = id, score = score, fields = fields)
            i += 2
        }
        return results
    }
}
