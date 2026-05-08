// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.VectorIndex
import dev.dazzle.sdk.WipeTarget
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.random.Random

/**
 * Diagnostic stress test for `VectorIndex.addBatchDirect` at the §5.9
 * scale (2 000 dim-384 vectors). Runs *without* BGE / Qwen so the
 * hang on Kirin 659 / EMUI 9 (which we observe in `RagE2EBenchTest`
 * after `embed loop done — starting addBatchDirect`) can be
 * isolated from the embedder + LLM mmap pressure.
 *
 * The test reports a fine-grained log line at each phase so the
 * point of stall is unambiguous when triaging the next chip:
 *
 *   - corpus generated
 *   - DazzleServer started
 *   - VectorIndex constructed
 *   - VectorIndex.create() returned
 *   - setAddBatchThreads(n) (env-pinned)
 *   - addBatchDirect entered (ts1)
 *   - addBatchDirect returned (ts2 - ts1 ms)
 *   - searchDirect smoke test (one query, k=5)
 *
 * Invocation:
 *   adb shell am instrument -w -r \
 *       -e class dev.dazzle.experiment.AddBatchStressTest \
 *       -e batch_threads 1 \
 *       -e n_vecs 2000 \
 *       dev.dazzle.experiment.storage.test/androidx.test.runner.AndroidJUnitRunner
 */
@RunWith(AndroidJUnit4::class)
class AddBatchStressTest {

    @Test
    fun addBatch2000Dim384HnswCosine() {
        val args = InstrumentationRegistry.getArguments()
        val nVecs = args.getString("n_vecs")?.toIntOrNull() ?: 2000
        val dim = args.getString("dim")?.toIntOrNull() ?: 384
        val batchThreads = args.getString("batch_threads")?.toIntOrNull() ?: 0
        val algoStr = args.getString("algo") ?: "HNSW"
        val algo = when (algoStr.uppercase()) {
            "FLAT"           -> VectorIndex.Algorithm.FLAT
            "HNSW_SQ8"       -> VectorIndex.Algorithm.HNSW_SQ8
            "HNSW_F16"       -> VectorIndex.Algorithm.HNSW_F16
            else             -> VectorIndex.Algorithm.HNSW
        }

        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        Log.i(TAG, "stress test: nVecs=$nVecs dim=$dim batchThreads=$batchThreads")

        val rng = Random(42)
        val ids = Array(nVecs) { "stress:$it" }
        val vecs = Array(nVecs) {
            FloatArray(dim) { rng.nextFloat() * 2f - 1f }
        }
        Log.i(TAG, "corpus generated (${nVecs * dim * 4} bytes)")

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(ctx, DazzleConfig(
            port        = 6390,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)
        Log.i(TAG, "DazzleServer started")

        try {
            if (batchThreads > 0) {
                VectorIndex.setAddBatchThreads(batchThreads)
                Log.i(TAG, "setAddBatchThreads($batchThreads)")
            }

            val dazzle = DazzleServer.client()
            val idx = dazzle.vectorIndex(
                name = "stress:idx",
                hashPrefix = "stress:",
                vectorField = "v",
                dim = dim,
                algorithm = algo,
                metric = VectorIndex.Metric.COSINE,
                initialCapacity = nVecs,  // pre-size so growCapacity is a no-op
            )
            Log.i(TAG, "VectorIndex constructed (algo=$algoStr)")

            val created = idx.create()
            Log.i(TAG, "VectorIndex.create() returned $created")

            val t0 = System.nanoTime()
            Log.i(TAG, "addBatchDirect entering with $nVecs vecs")
            idx.addBatchDirect(ids, vecs)
            val tMs = (System.nanoTime() - t0) / 1_000_000L
            Log.i(TAG, "addBatchDirect returned in ${tMs} ms")

            // Smoke test the index works
            val q = vecs[0]
            val hits = idx.searchDirect(q, k = 5)
            Log.i(TAG, "searchDirect returned ${hits.size} hits, first=${hits.firstOrNull()?.first}")
        } finally {
            try { DazzleServer.stop() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "AddBatchStress"
    }
}
