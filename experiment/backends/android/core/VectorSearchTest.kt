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
import android.util.Log
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
 * Validates DazzleModule.VectorSearch (dazzle-search HNSW module) on device.
 *
 * Plan 17 — vector module smoke test:
 *   1. Start Dazzle with DazzleModule.VectorSearch
 *   2. FT.CREATE index (dim=16, HNSW, COSINE)
 *   3. HSET 500 docs with random FLOAT32 embeddings → auto-indexed via keyspace notification
 *   4. 100 FT.SEARCH KNN-10 queries → report avg latency
 *   5. Verify top-1 of self-search returns the same key (recall check)
 *
 * Results written to /sdcard/Documents/plan17_vector_search_<device>.json
 *
 * adb:
 *   adb shell am start -n dev.dazzle.experiment.storage/.StorageActivity \
 *     --es backend dazzle-vector
 */
object VectorSearchTest {

    private const val TAG = "VectorTest"
    private const val DIM = 16
    private const val N_DOCS = 500
    private const val N_QUERIES = 100
    private const val K = 10

    data class Result(
        val device: String,
        val dim: Int,
        val nDocs: Int,
        val nQueries: Int,
        val k: Int,
        val indexCreateUs: Long,
        val ingestTotalMs: Long,
        val ingestAvgUs: Double,
        val searchAvgUs: Double,
        val searchP95Us: Long,
        val selfRecallAt1: Double,
        val error: String? = null,
    )

    fun run(context: Context, outputDir: java.io.File? = null): Result {
        Log.i(TAG, "══ VectorSearchTest (plan17) dim=$DIM N=$N_DOCS ══")

        // Start with VectorSearch module
        if (DazzleServer.isRunning()) DazzleServer.stop()
        val t0 = System.nanoTime()
        DazzleServer.start(context, DazzleConfig(
            port        = 6381,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(500) // let module load
        val startMs = (System.nanoTime() - t0) / 1_000_000L
        Log.i(TAG, "server started in ${startMs}ms")

        val dazzle = DazzleServer.client()

        // FT.CREATE
        val idx = dazzle.vectorIndex(
            name        = "docs",
            hashPrefix  = "doc:",
            vectorField = "emb",
            dim         = DIM,
            algorithm   = VectorIndex.Algorithm.HNSW,
            metric      = VectorIndex.Metric.COSINE,
        )
        val createStart = System.nanoTime()
        val created = idx.create()
        val createUs = (System.nanoTime() - createStart) / 1_000L
        Log.i(TAG, "FT.CREATE: $created in ${createUs}µs")
        check(created) { "FT.CREATE failed" }

        // Generate deterministic random docs
        val rng = Random(42)
        val docs = Array(N_DOCS) { i ->
            val vec = FloatArray(DIM) { rng.nextFloat() * 2f - 1f }
            "doc:$i" to vec
        }

        // Probe FT.HADD with first doc — log raw reply to catch silent errors
        val (probeId, probeVec) = docs[0]
        val probeReply = DazzleServer.directCommand("FT.HADD", idx.name, probeId, idx.vectorField,
            android.util.Base64.encodeToString(
                java.nio.ByteBuffer.allocate(probeVec.size * 4)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .also { probeVec.forEach(it::putFloat) }.array(),
                android.util.Base64.NO_WRAP
            )
        )
        Log.i(TAG, "FT.HADD probe reply: $probeReply")

        // HSET all docs (auto-indexed via keyspace notification)
        val ingestTimes = LongArray(N_DOCS)
        for ((i, pair) in docs.withIndex()) {
            val (id, vec) = pair
            val ts = System.nanoTime()
            idx.add(id, vec, mapOf("idx" to i.toString()))
            ingestTimes[i] = (System.nanoTime() - ts) / 1_000L
        }
        val ingestTotalMs = ingestTimes.sum() / 1_000L
        val ingestAvgUs = ingestTimes.average()
        Log.i(TAG, "ingest ${N_DOCS} docs: total=${ingestTotalMs}ms avg=${ingestAvgUs.toLong()}µs")

        // Probe FT.SEARCH: log first result AND verify metadata fields are present
        val (firstId, firstVec) = docs[0]
        val firstResults = idx.search(firstVec, 3)
        Log.i(TAG, "FT.SEARCH probe [query=doc:0]: ${firstResults.map { "${it.id}@${it.score}" }}")
        if (firstResults.isNotEmpty()) {
            val topFields = firstResults[0].fields
            val idxVal = topFields["idx"]
            Log.i(TAG, "FIELD_CHECK: r.fields[\"idx\"]=${idxVal} allFields=${topFields.keys.sorted()}")
            if (idxVal == null) {
                Log.e(TAG, "FIELD_CHECK FAIL: metadata field 'idx' is null — FT.HADD fields NOT in r.fields")
            } else {
                Log.i(TAG, "FIELD_CHECK PASS: metadata fields present in r.fields")
            }
        }

        // FT.SEARCH latency
        val searchTimes = LongArray(N_QUERIES)
        var selfRecallHits = 0
        for (q in 0 until N_QUERIES) {
            val (queryId, queryVec) = docs[q % N_DOCS]
            val ts = System.nanoTime()
            val results = idx.search(queryVec, K)
            searchTimes[q] = (System.nanoTime() - ts) / 1_000L

            if (results.isNotEmpty() && results[0].id == queryId) selfRecallHits++
        }
        searchTimes.sort()
        val searchAvgUs = searchTimes.average()
        val searchP95Us = searchTimes[(N_QUERIES * 0.95).toInt()]
        val selfRecallAt1 = selfRecallHits.toDouble() / N_QUERIES
        Log.i(TAG, "FT.SEARCH avg=${searchAvgUs.toLong()}µs p95=${searchP95Us}µs recall@1=${selfRecallAt1}")

        val device = "${android.os.Build.MODEL} (API ${android.os.Build.VERSION.SDK_INT})"
        val result = Result(
            device         = device,
            dim            = DIM,
            nDocs          = N_DOCS,
            nQueries       = N_QUERIES,
            k              = K,
            indexCreateUs  = createUs,
            ingestTotalMs  = ingestTotalMs,
            ingestAvgUs    = ingestAvgUs,
            searchAvgUs    = searchAvgUs,
            searchP95Us    = searchP95Us,
            selfRecallAt1  = selfRecallAt1,
        )

        writeResult(context, result, outputDir)
        DazzleServer.stop()
        return result
    }

    private fun writeResult(context: Context, result: Result, outputDir: java.io.File?) {
        try {
            val dir = outputDir ?: run {
                val ext = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOCUMENTS
                )
                if (android.os.Environment.getExternalStorageState() ==
                        android.os.Environment.MEDIA_MOUNTED) ext
                else context.filesDir
            }
            dir.mkdirs()
            val safe = result.device.replace(Regex("[^A-Za-z0-9_-]"), "_")
            val f = File(dir, "plan17_vector_search_${safe}.json")
            f.writeText(buildString {
                appendLine("{")
                appendLine("  \"device\": \"${result.device}\",")
                appendLine("  \"dim\": ${result.dim},")
                appendLine("  \"n_docs\": ${result.nDocs},")
                appendLine("  \"n_queries\": ${result.nQueries},")
                appendLine("  \"k\": ${result.k},")
                appendLine("  \"index_create_us\": ${result.indexCreateUs},")
                appendLine("  \"ingest_total_ms\": ${result.ingestTotalMs},")
                appendLine("  \"ingest_avg_us\": ${result.ingestAvgUs},")
                appendLine("  \"search_avg_us\": ${result.searchAvgUs},")
                appendLine("  \"search_p95_us\": ${result.searchP95Us},")
                appendLine("  \"self_recall_at1\": ${result.selfRecallAt1}")
                append("}")
            })
            Log.i(TAG, "result written to ${f.absolutePath}")
        } catch (e: Exception) {
            Log.w(TAG, "could not write result: ${e.message}")
        }
    }
}
