// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumentation entry point for the §5.9 RAG E2E bench.
 *
 * Why this exists: on EMUI 9.1.0 (Kirin 659 / ANE-LX3), launching the
 * bench through `StorageActivity` gets the process demoted to
 * `WORKINGSET_BACKGROUND` (iAware subCmd 352) within ~10 seconds of
 * foreground grant — regardless of notification importance, foreground
 * service, battery whitelist, deviceidle whitelist, or simulated touch
 * input. After demotion the bench thread receives essentially no CPU
 * and the run never makes it past `embed passage 1/2000`.
 *
 * Tests launched via `am instrument` run inside an instrumentation
 * process attached by `Instrumentation.onCreate()` rather than as a
 * regular foreground activity. EMUI iAware leaves instrumentation
 * processes alone — the same code path that froze on Kirin 659 from
 * the activity finishes the full §5.9 bench (BGE + Qwen 0.5B +
 * Qwen 1.5B + 200 NQ queries) without intervention.
 *
 * Invocation:
 *   adb shell am instrument -w \
 *       -e backend rag-e2e \
 *       -e flash_attn false \
 *       dev.dazzle.experiment.storage.test/androidx.test.runner.AndroidJUnitRunner
 *
 * Optional `-e` extras (mirrored from `StorageActivity` intent extras):
 *   -e kv_cache F16|Q8_0|Q4_0     # default F16 (paper baseline)
 *   -e flash_attn true|false       # default auto-detect via FP16 hw
 *   -e use_mlock true|false        # default false
 *   -e max_queries N               # default null (run all 200)
 *
 * The test sets the same system properties StorageActivity sets when
 * given matching intent extras, so `RagE2EBench.run` reads them
 * verbatim — no separate code path. Output JSON is written to
 * `/sdcard/Documents/rag_e2e_<MODEL>_<TS>.json` exactly as in the
 * activity-launched run.
 */
@RunWith(AndroidJUnit4::class)
class RagE2EBenchTest {

    @Test
    fun runRagE2EFullBench() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val args: Bundle = InstrumentationRegistry.getArguments()

        // Pass through the same overrides StorageActivity reads from
        // its intent. Empty / missing → keep paper-baseline defaults.
        args.getString("kv_cache")?.let {
            System.setProperty("dazzle.bench.kv_cache", it)
            android.util.Log.i(TAG, "kv_cache override: $it")
        }
        args.getString("flash_attn")?.let {
            System.setProperty("dazzle.bench.flash_attn", it)
            android.util.Log.i(TAG, "flash_attn override: $it")
        }
        args.getString("use_mlock")?.let {
            System.setProperty("dazzle.bench.use_mlock", it)
            android.util.Log.i(TAG, "use_mlock override: $it")
        }
        args.getString("n_threads")?.let {
            System.setProperty("dazzle.bench.n_threads", it)
            android.util.Log.i(TAG, "n_threads override: $it")
        }
        args.getString("ef_construction")?.let {
            System.setProperty("dazzle.bench.ef_construction", it)
            android.util.Log.i(TAG, "ef_construction override: $it")
        }
        args.getString("batch_threads")?.let {
            System.setProperty("dazzle.bench.batch_threads", it)
            android.util.Log.i(TAG, "batch_threads override: $it")
        }
        args.getString("algo")?.let {
            System.setProperty("dazzle.bench.algo", it.uppercase())
            android.util.Log.i(TAG, "algo override: $it")
        }
        args.getString("max_queries")?.let {
            System.setProperty("dazzle.bench.max_queries", it)
            android.util.Log.i(TAG, "max_queries override: $it")
        }
        args.getString("use_mmap")?.let {
            System.setProperty("dazzle.bench.use_mmap", it)
            android.util.Log.i(TAG, "use_mmap override: $it")
        }

        android.util.Log.i(TAG, "starting RagE2EBench via instrumentation runner")
        StorageOnlyTest.run(context, "rag-e2e")
        android.util.Log.i(TAG, "RagE2EBench finished cleanly")
    }

    /**
     * Multi-process driver — phase 1: embed-only. Persist binaries to
     * /sdcard/Documents/rag_kirin_split/. No LLM is opened in this
     * process, so iAware's kill-score never reaches the LLM-load
     * trigger threshold on Kirin 659 / EMUI 9.
     */
    @Test
    fun runRagE2EPhaseEmbed() {
        propagateExtras()
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        RagE2EBenchPhases.runEmbedPhase(ctx)
    }

    /**
     * Multi-process driver — phase 2a: small variants (A + C). Fresh
     * process. Reads cache, opens Qwen 0.5B, runs both small variants,
     * writes `partial_small.json`. Exits before iAware can build a kill
     * score on this process.
     */
    @Test
    fun runRagE2EPhaseSmall() {
        propagateExtras()
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        RagE2EBenchPhases.runSmallPhase(ctx)
    }

    /** Multi-process driver — phase 2b: large variants (B + D). */
    @Test
    fun runRagE2EPhaseLarge() {
        propagateExtras()
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        RagE2EBenchPhases.runLargePhase(ctx)
    }

    /** Multi-process driver — phase 3: merge partials into bench JSON. */
    @Test
    fun runRagE2EPhaseMerge() {
        propagateExtras()
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        RagE2EBenchPhases.runMergePhase(ctx)
    }

    /** Chunked single-variant phase. Pass `-e variant <name> -e q_offset N -e q_limit N`. */
    @Test
    fun runRagE2EVariantChunk() {
        propagateExtras()
        val args = InstrumentationRegistry.getArguments()
        val variant = args.getString("variant")
            ?: error("missing -e variant {small_rag|small_no_rag|large_rag|large_no_rag}")
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        RagE2EBenchPhases.runVariantChunk(ctx, variant)
    }

    private fun propagateExtras() {
        val args = InstrumentationRegistry.getArguments()
        for (key in listOf("kv_cache", "flash_attn", "use_mlock", "n_threads",
                            "ef_construction", "batch_threads", "algo",
                            "max_queries", "use_mmap",
                            "llm_n_batch", "llm_n_ctx",
                            "q_offset", "q_limit")) {
            args.getString(key)?.let {
                System.setProperty("dazzle.bench.$key", it)
                android.util.Log.i(TAG, "$key override: $it")
            }
        }
    }

    /**
     * Scale probe: build a FLAT index with N=2000 dim=384 (paper config),
     * issue 10 random searches. Pinpoints whether the SDK FLAT-path
     * scalar scan crashes at production scale.
     */
    @Test
    fun probeFlatScale() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        if (!dev.dazzle.sdk.DazzleServer.isRunning()) {
            dev.dazzle.sdk.DazzleServer.start(ctx, dev.dazzle.sdk.DazzleConfig(
                tcpEnabled = true, port = 6380,
                persistence = dev.dazzle.sdk.DazzlePersistence.None,
                wipeOnStart = setOf(
                    dev.dazzle.sdk.WipeTarget.AOF,
                    dev.dazzle.sdk.WipeTarget.RDB),
                modules = setOf(dev.dazzle.sdk.DazzleModule.VectorSearch),
            ))
            Thread.sleep(800)
        }
        val server = dev.dazzle.sdk.DazzleServer.client()
        val n = 2000; val d = 384
        val idx = server.vectorIndex(
            name            = "probe:flat:scale",
            hashPrefix      = "probe:flat:scale:",
            vectorField     = "emb",
            dim             = d,
            algorithm       = dev.dazzle.sdk.VectorIndex.Algorithm.FLAT,
            metric          = dev.dazzle.sdk.VectorIndex.Metric.COSINE,
            initialCapacity = n,
        )
        idx.create()
        val rng = java.util.Random(42)
        val ids = Array(n) { "probe:flat:scale:$it" }
        val vecs = Array(n) { FloatArray(d) { rng.nextFloat() - 0.5f } }
        val t0 = System.nanoTime()
        idx.addBatchDirect(ids, vecs)
        android.util.Log.i(TAG, "scale: addBatchDirect $n×$d in ${(System.nanoTime()-t0)/1_000_000}ms")
        for (s in 0 until 10) {
            val q = FloatArray(d) { rng.nextFloat() - 0.5f }
            val ts = System.nanoTime()
            val hits = idx.searchDirect(q, k = 5, efRuntime = 0)
            val tms = (System.nanoTime() - ts) / 1_000L
            android.util.Log.i(TAG, "scale: search[$s] hits=${hits.size} in ${tms}us")
        }
    }

    /**
     * Probe: build a tiny FLAT index, addBatchDirect 5 vectors, search.
     * If hits.size != 5 the bug is FLAT-path-specific in the SDK. If
     * hits.size == 5 the bug is in the multi-process driver or in how
     * RagE2EBench's runVariantRag interacts with the FLAT index.
     */
    @Test
    fun probeFlatSearchRoundtrip() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        if (!dev.dazzle.sdk.DazzleServer.isRunning()) {
            dev.dazzle.sdk.DazzleServer.start(ctx, dev.dazzle.sdk.DazzleConfig(
                tcpEnabled = true, port = 6380,
                persistence = dev.dazzle.sdk.DazzlePersistence.None,
                wipeOnStart = setOf(
                    dev.dazzle.sdk.WipeTarget.AOF,
                    dev.dazzle.sdk.WipeTarget.RDB),
                modules = setOf(dev.dazzle.sdk.DazzleModule.VectorSearch),
            ))
            Thread.sleep(800)
        }
        val server = dev.dazzle.sdk.DazzleServer.client()
        val idx = server.vectorIndex(
            name            = "probe:flat",
            hashPrefix      = "probe:flat:",
            vectorField     = "emb",
            dim             = 4,
            algorithm       = dev.dazzle.sdk.VectorIndex.Algorithm.FLAT,
            metric          = dev.dazzle.sdk.VectorIndex.Metric.COSINE,
            initialCapacity = 16,
        )
        val created = idx.create()
        android.util.Log.i(TAG, "probe-flat: created=$created")
        val ids = arrayOf(
            "probe:flat:a", "probe:flat:b", "probe:flat:c",
            "probe:flat:d", "probe:flat:e",
        )
        val vecs: Array<FloatArray> = arrayOf(
            floatArrayOf(1f, 0f, 0f, 0f),
            floatArrayOf(0f, 1f, 0f, 0f),
            floatArrayOf(0f, 0f, 1f, 0f),
            floatArrayOf(0f, 0f, 0f, 1f),
            floatArrayOf(0.5f, 0.5f, 0.5f, 0.5f),
        )
        idx.addBatchDirect(ids, vecs)
        android.util.Log.i(TAG, "probe-flat: addBatchDirect 5 vectors done")
        val q = floatArrayOf(0.9f, 0.1f, 0f, 0f)
        val hits = idx.searchDirect(q, k = 3, efRuntime = 0)
        android.util.Log.i(TAG, "probe-flat: search returned ${hits.size} hits")
        for (h in hits) android.util.Log.i(TAG, "probe-flat:   id=${h.first} dist=${h.second}")
        if (hits.isEmpty()) {
            android.util.Log.e(TAG, "probe-flat: FAIL — FLAT search returned 0 hits")
        }
    }

    /**
     * Standalone probe: open Qwen 0.5B and immediately close. No embed
     * phase, no queries. Used to test the hypothesis that the iAware kill
     * on Kirin 659 / EMUI 9 is triggered by the cumulative score after
     * the embed loop, not by the LLM mmap itself. If THIS test survives,
     * the bench needs to be split into per-phase `am instrument` calls
     * so each phase starts with a fresh iAware score.
     */
    @Test
    fun probeQwenSmallLoadOnly() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        android.util.Log.i(TAG, "probe: opening Qwen 0.5B from a fresh process")
        val small = java.io.File(context.filesDir, "gen/qwen2.5-0.5b-instruct-q4_k_m.gguf")
        android.util.Log.i(TAG, "probe: path=${small.absolutePath} exists=${small.exists()} size=${small.length()}")
        val t0 = System.nanoTime()
        val llm = dev.dazzle.experiment.DazzleLlm.open(
            context, small.absolutePath,
            nCtx = 2048, nBatch = 512,
            kvCacheType = dev.dazzle.experiment.KvCacheType.F16,
            flashAttention = false, useMlock = false,
        )
        val tLoadMs = (System.nanoTime() - t0) / 1_000_000L
        android.util.Log.i(TAG, "probe: Qwen 0.5B opened in ${tLoadMs}ms — closing")
        llm.close()
        android.util.Log.i(TAG, "probe: closed cleanly")
    }

    companion object {
        private const val TAG = "RagE2EBenchTest"
    }
}
