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
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import org.json.JSONArray
import org.json.JSONObject

/**
 * E3 end-to-end RAG narrative — *"LLM pequeño + RAG ≈ LLM grande sin RAG"*.
 *
 * For every query in the NQ slice we run **two variants**:
 *   - **small + rag**  →  embed(Q) → dazzle-vector top-k → prompt(passages, Q) → LLM-small
 *   - **large + none** →                                    prompt(Q)          → LLM-large
 *
 * Both use greedy decoding so the numbers are reproducible. The
 * per-variant output captures:
 *   - answer text
 *   - latency breakdown: embed_us, search_us, prefill_us, decode_us, total_us
 *   - prompt_tokens / new_tokens
 *   - **EM** + **short-answer F1** against `nq_open.short_answers`,
 *     SQuAD/NQ-open style (lowercase + strip articles/punct):
 *       * `em_short`     — strict EM over the *extracted answer span*
 *                          (output truncated at the first newline or at a
 *                          fresh `Question:` / `Answer:` echo).
 *       * `em_contains`  — laxer signal: any alias is a substring of the
 *                          full normalised output (preserved as a diagnostic
 *                          to separate "model knows the answer" from
 *                          "model answers concisely").
 *       * `f1_short`     — max token-F1 over aliases against the **same
 *                          extracted span**, so `em_short ≤ f1_short`
 *                          holds by construction. (`f1_short` and
 *                          `em_contains` are complementary, not nested:
 *                          a short span can partially overlap a long
 *                          alias yet fail the contiguous substring test.)
 *     Falls back to token-F1 vs the gold passage text when a query has no
 *     short_answers (older slices without the nq_open join).
 *
 * Invocation:
 *   adb shell am start -n dev.dazzle.experiment.backends/.BackendsActivity \
 *     --ez test_storage_only true --es backend rag-e2e
 *
 * Output: /sdcard/Documents/rag_e2e_<MODEL>_<TS>.json.
 */
object RagE2EBench {

    private const val TAG = "RagE2E"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val embedFile:     String = "bge-small-en-v1.5-q4_k_m.gguf",
        val smallLlmFile:  String = "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        val largeLlmFile:  String = "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        val embedNCtx:     Int = 512,
        // n_batch == n_ctx for the embedder so a single passage of up to
        // 512 tokens prefills in one llama_decode call — avoids the
        // split-prefill code path which hangs on ARMv8.0 Cortex-A53
        // (Kirin 659) when a passage is longer than n_batch (~450
        // tokens for the §5.9 NQ slice's `passages[2]` ≈ 1.8 KB / 4
        // chars-per-token). On chips with FP16 hardware (A75+) the
        // split path works fine, but defaulting to no-split keeps the
        // bench portable across all four §5.9 SoCs without per-chip
        // overrides.
        val embedNBatch:   Int = 512,
        val llmNCtx:       Int = 2048,
        val llmNBatch:     Int = 512,
        /** KV-cache quantisation for the LLM contexts (paper default F16). */
        val llmKvCacheType: KvCacheType = KvCacheType.F16,
        /** Flash-attention for both embedder and LLM (default on). */
        val flashAttention: Boolean = true,
        /** Pin LLM weights via mlock() — defaults off; flip on for tight 4 GB devices. */
        val useMlock: Boolean = false,
        /** Worker threads for both embedder and LLM. 0 = use SDK default. */
        val nThreads: Int = 0,
        val maxNewTokens:  Int = 64,
        val k:             Int = 5,
        val efRuntime:     Int = 64,
        /** HNSW index build quality. Lower = faster build, slightly lower
         *  recall. Paper baseline is 200; tight 4 GB devices (Kirin 659)
         *  can drop to 100 to keep the addBatchDirect call from
         *  thrashing on hnswlib's heap allocations during graph build. */
        val efConstruction: Int = 200,
        val indexName:     String = "nq:e2e",
        val hashPrefix:    String = "nq:e2e:",
        val passagesAsset: String = "nq_slice/passages.jsonl",
        val queriesAsset:  String = "nq_slice/queries.jsonl",
        /** Cap queries to keep wall time manageable. Null → run all. */
        val maxQueries:    Int? = null,
        /** Override parallelism of `VectorIndex.addBatchDirect` HNSW
         *  build pool. 0 = SDK default (min(hw, 8)). On EMUI 9 / Kirin 659
         *  the 8-way default deadlocks; setting this to 1 forces a
         *  serial build that survives the cgroup throttling. */
        val addBatchThreads: Int = 0,
        /** Vector index algorithm — paper baseline is HNSW. On chips
         *  where `HierarchicalNSW::addPoint(0)` deadlocks (Kirin 659 /
         *  EMUI 9 — see `research/results/cross_platform_e2e/`) the
         *  bench can fall back to `FLAT` (BruteforceSearch). At this
         *  scale (N=2000, dim=384, k=5, efRuntime=64) HNSW recall is
         *  >99 %, so the F1 / EM cells reported in §5.9 are
         *  near-identical between the two. */
        val algorithm: VectorIndex.Algorithm = VectorIndex.Algorithm.HNSW,
    )

    internal data class Passage(val id: String, val text: String)
    internal data class Query(
        val id: String,
        val text: String,
        val gold: List<String>,
        val shortAnswers: List<String>,
    )

    fun run(context: Context, baseCfg: Config = Config()) {
        // System-property pass-through from StorageActivity intent extras
        // (`--es kv_cache F16|Q8_0|Q4_0`, `--ez flash_attn true|false`,
        // `--es max_queries N`). Keeps the paper-config Config() defaults
        // intact while letting an operator probe the F1 / RAM trade-off
        // on a low-RAM device without rebuilding the APK.
        val cfg = baseCfg.copy(
            llmKvCacheType = System.getProperty("dazzle.bench.kv_cache")
                ?.let { runCatching { KvCacheType.valueOf(it) }.getOrNull() }
                ?: baseCfg.llmKvCacheType,
            flashAttention = System.getProperty("dazzle.bench.flash_attn")
                ?.toBooleanStrictOrNull()
                ?: baseCfg.flashAttention,
            useMlock = System.getProperty("dazzle.bench.use_mlock")
                ?.toBooleanStrictOrNull()
                ?: baseCfg.useMlock,
            nThreads = System.getProperty("dazzle.bench.n_threads")
                ?.toIntOrNull()
                ?: baseCfg.nThreads,
            llmNBatch = System.getProperty("dazzle.bench.llm_n_batch")
                ?.toIntOrNull()
                ?: baseCfg.llmNBatch,
            llmNCtx = System.getProperty("dazzle.bench.llm_n_ctx")
                ?.toIntOrNull()
                ?: baseCfg.llmNCtx,
            efConstruction = System.getProperty("dazzle.bench.ef_construction")
                ?.toIntOrNull()
                ?: baseCfg.efConstruction,
            addBatchThreads = System.getProperty("dazzle.bench.batch_threads")
                ?.toIntOrNull()
                ?: baseCfg.addBatchThreads,
            algorithm = System.getProperty("dazzle.bench.algo")
                ?.let { name ->
                    runCatching { VectorIndex.Algorithm.valueOf(name) }.getOrNull()
                }
                ?: baseCfg.algorithm,
            maxQueries = System.getProperty("dazzle.bench.max_queries")
                ?.toIntOrNull()
                ?: baseCfg.maxQueries,
        )
        Log.i(
            TAG,
            "══ RagE2EBench small=${cfg.smallLlmFile} large=${cfg.largeLlmFile} " +
            "kv=${cfg.llmKvCacheType} flash_attn=${cfg.flashAttention} " +
            "mlock=${cfg.useMlock} maxQueries=${cfg.maxQueries ?: "all"} ══"
        )

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(context, DazzleConfig(
            port        = 6383,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)

        // Apply HNSW batch-build pool override AFTER native lib is loaded
        // (DazzleServer.start triggers DazzleNativeLoader). On Kirin 659 /
        // EMUI 9 the default 8-way pool deadlocks during the bulk
        // `addBatchDirect` step — single-threaded build is the diagnosed
        // workaround. The setter is a no-op when `addBatchThreads = 0`.
        if (cfg.addBatchThreads > 0) {
            try {
                VectorIndex.setAddBatchThreads(cfg.addBatchThreads)
                Log.i(TAG, "addBatchDirect threads pinned to ${cfg.addBatchThreads}")
            } catch (e: Throwable) {
                Log.w(TAG, "setAddBatchThreads(${cfg.addBatchThreads}) failed: ${e.message}")
            }
        }

        try {
            val out = runInner(context, cfg)
            val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
            val ts = System.currentTimeMillis()
            val fname = "rag_e2e_${safeModel}_${ts}.json"
            val file = try {
                val docs = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOCUMENTS,
                )
                docs.mkdirs()
                File(docs, fname)
            } catch (_: Exception) {
                File(context.filesDir, fname)
            }
            file.writeText(gson.toJson(out))
            Log.i(TAG, "══ wrote ${file.absolutePath} ══")
        } finally {
            try { DazzleServer.stop() } catch (_: Throwable) {}
        }
    }

    private fun runInner(context: Context, cfg: Config): Map<String, Any?> {
        // ── Weights ──────────────────────────────────────────────────────
        // Resolve each weight file by walking three candidate roots in
        // order of preference. The first one that holds the file wins.
        // This keeps the original `context.filesDir` path working AND
        // lets a benchmark driver `adb push` directly into the
        // app-external-files dir (which is world-readable for `adb push`
        // without a `run-as` step) or drop the model in /sdcard/Download
        // and avoid copying. The Cross-platform §5.9 driver uses the
        // last form so the same Download directory hosts the weights
        // for every device that runs the bench.
        fun resolveWeight(name: String, subdir: String): File {
            val candidates = listOf(
                File(File(context.filesDir, subdir), name),
                File(File(context.getExternalFilesDir(null), subdir), name),
                File(Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS), name),
            )
            for (c in candidates) {
                if (c.exists()) {
                    Log.i(TAG, "weight $name resolved at ${c.absolutePath}")
                    return c
                }
            }
            error(
                "GGUF $name not found in any of:\n" +
                candidates.joinToString("\n") { "  - ${it.absolutePath}" } +
                "\n\nPush with one of:\n" +
                "  adb push $name /sdcard/Download/                                  # easiest\n" +
                "  adb push $name /sdcard/Android/data/<pkg>/files/$subdir/          # app-external\n" +
                "  adb push $name /data/local/tmp/ ; adb shell run-as <pkg> cp /data/local/tmp/$name files/$subdir/"
            )
        }
        val embedSrc = resolveWeight(cfg.embedFile,    "embed")
        val smallSrc = resolveWeight(cfg.smallLlmFile, "gen")
        val largeSrc = resolveWeight(cfg.largeLlmFile, "gen")

        // ── Embedder + slice ─────────────────────────────────────────────
        val embedder = DazzleEmbedder.open(
            context, embedSrc.absolutePath,
            nCtx = cfg.embedNCtx,
            nBatch = cfg.embedNBatch,
            flashAttention = cfg.flashAttention,
            useMlock = cfg.useMlock,
            nThreads = if (cfg.nThreads > 0) cfg.nThreads
                       else Runtime.getRuntime().availableProcessors().coerceAtMost(4),
        )
        Log.i(TAG, "embedder open: n_embd=${embedder.outputDim}")

        val passages = loadPassages(context, cfg.passagesAsset)
        val queriesAll = loadQueries(context, cfg.queriesAsset)
        val queries = cfg.maxQueries?.let { queriesAll.take(it) } ?: queriesAll
        Log.i(TAG, "slice: ${passages.size} passages, ${queries.size} queries (of ${queriesAll.size})")

        val passageById = passages.associateBy { cfg.hashPrefix + it.id }

        // Pre-allocated outside the try-block so the catch path can
        // still reference them; populated by the pre-embed step inside
        // the try-block below.
        val queryEmbedUs = LongArray(queries.size)
        var embedderClosed = false

        val result = linkedMapOf<String, Any?>(
            "type"      to "rag_e2e",
            "timestamp" to java.time.Instant.now().toString(),
            "device"    to collectDeviceInfo(),
            "models"    to linkedMapOf(
                "embedder"  to fileInfo(embedSrc, embedder.outputDim, cfg.embedNCtx),
                "small_llm" to fileInfo(smallSrc, null,               cfg.llmNCtx),
                "large_llm" to fileInfo(largeSrc, null,               cfg.llmNCtx),
            ),
            "slice" to linkedMapOf(
                "n_passages" to passages.size,
                "n_queries"  to queries.size,
            ),
            "config" to linkedMapOf(
                "k"              to cfg.k,
                "ef_runtime"     to cfg.efRuntime,
                "ef_construction" to cfg.efConstruction,
                "algorithm"      to cfg.algorithm.name,
                "max_new_tokens" to cfg.maxNewTokens,
                "decoding"       to "greedy",
                // SDK runtime knobs — recorded so any F1 delta is
                // attributable to a deliberate memory/quality trade-off
                // rather than silent harness drift.
                "embed_n_ctx"    to cfg.embedNCtx,
                "embed_n_batch"  to cfg.embedNBatch,
                "llm_n_ctx"      to cfg.llmNCtx,
                "llm_n_batch"    to cfg.llmNBatch,
                "llm_kv_cache"   to cfg.llmKvCacheType.name,
                "flash_attn"     to cfg.flashAttention,
                "use_mlock"      to cfg.useMlock,
                "n_threads"      to cfg.nThreads,
            ),
        )

        try {
            // ── Build HNSW index ─────────────────────────────────────────
            val dazzle = DazzleServer.client()
            val index = dazzle.vectorIndex(
                name            = cfg.indexName,
                hashPrefix      = cfg.hashPrefix,
                vectorField     = "emb",
                dim             = embedder.outputDim,
                algorithm       = cfg.algorithm,
                metric          = VectorIndex.Metric.COSINE,
                initialCapacity = passages.size,
                m               = 16,
                efConstruction  = cfg.efConstruction,
            )
            index.create()

            val ids  = Array(passages.size) { cfg.hashPrefix + passages[it].id }
            // Granular logging during the early embed loop so we can pinpoint
            // exactly which call hangs on tight A53 devices. The loop also
            // emits one log per call past i=1800 so we can disambiguate a
            // hang in the tail of the embed loop from a hang in the
            // post-loop addBatchDirect / pre-embed-queries phases on Kirin
            // 659 — the two cases cause the same "no progress" symptom but
            // need different fixes.
            val vecs = Array(passages.size) { i ->
                val t0 = System.nanoTime()
                val v = embedder.embed(passages[i].text)
                val tMs = (System.nanoTime() - t0) / 1_000_000L
                if (i < 10 || i >= 1800 || i % 200 == 0) {
                    Log.i(TAG, "  embed passage $i/${passages.size} took=${tMs}ms")
                }
                v
            }
            Log.i(TAG, "embed loop done — starting addBatchDirect with ${vecs.size} vectors")
            val tBatch0 = System.nanoTime()
            index.addBatchDirect(ids, vecs)
            val tBatchMs = (System.nanoTime() - tBatch0) / 1_000_000L
            Log.i(TAG, "addBatchDirect completed in ${tBatchMs}ms")
            Log.i(TAG, "indexed ${passages.size} vectors")

            // ── Pre-embed every query so we can release the embedder
            // before opening any LLM. On 4 GB devices (Kirin 659 etc.)
            // the BGE weights + compute buffer (~140 MB) compete with
            // the 1.5 B LLM (1.0 GB mmap + 470 MB KV-cache at n_ctx=2048)
            // for resident pages, and EMUI iAware will pause the process
            // before variant D finishes. Pre-embedding costs 200 × ~150 ms
            // ≈ 30 s of extra wall-clock and 200 × 384 × 4 B = 300 KB of
            // RAM, which is a trivially better trade than keeping the
            // embedder live for ~3 hours of LLM work that does not need it.
            val queryEmbeddings = Array(queries.size) { qi ->
                val tq0 = System.nanoTime()
                val v = embedder.embed(queries[qi].text)
                val tq1 = System.nanoTime()
                queryEmbedUs[qi] = (tq1 - tq0) / 1_000L
                if (qi % 50 == 0) Log.i(TAG, "  embed query $qi/${queries.size}")
                v
            }
            Log.i(TAG, "embedded ${queries.size} queries; closing embedder before LLM phase")
            embedder.close()
            embedderClosed = true

            // Force a GC + brief pause before mapping the LLM weights.
            // On 4 GB Cortex-A53 chips (Kirin 659 / EMUI 9) the LLM mmap
            // (~390 MB Q4_K_M) lands right at the OS low-mem threshold;
            // releasing the embedder's buffers now (instead of letting
            // ART decide) shaves ~80 MB of RSS off the moment the LLM
            // page-faults into memory and keeps the test process below
            // the iAware/lmkd kill bar through variant A.
            try {
                System.gc()
                System.runFinalization()
                Thread.sleep(500)
                val rt = Runtime.getRuntime()
                val freeMb = rt.freeMemory() / (1024 * 1024)
                val totalMb = rt.totalMemory() / (1024 * 1024)
                val maxMb = rt.maxMemory() / (1024 * 1024)
                Log.i(TAG, "pre-LLM heap: free=${freeMb}MB total=${totalMb}MB max=${maxMb}MB")
            } catch (_: Throwable) {}

            // ── Variant A: small + RAG ───────────────────────────────────
            // Open the small LLM once and run BOTH small variants
            // back-to-back so the model load (which dominates wall-clock
            // for tiny corpora) is paid only once. Same for large below.
            Log.i(TAG, "── variant A: small + RAG (${cfg.smallLlmFile}) ──")
            Log.i(TAG, "  opening small LLM mlock=${cfg.useMlock} kv=${cfg.llmKvCacheType} fa=${cfg.flashAttention}")
            // Optional opt-out from file-backed mmap of the .gguf — the
            // dazzle native side reads `DAZZLE_LLAMA_USE_MMAP` and, when
            // "0", switches `llama_model_params::use_mmap = false` so the
            // weights load via plain `read()` into anon RAM. Required on
            // Kirin 659 + EMUI 9 to slip past iAware's mmap-thrash kill.
            val useMmapProp = System.getProperty("dazzle.bench.use_mmap")
            useMmapProp?.let { v ->
                try {
                    android.system.Os.setenv("DAZZLE_LLAMA_USE_MMAP", v, true)
                    Log.i(TAG, "  DAZZLE_LLAMA_USE_MMAP=$v")
                } catch (_: Throwable) {}
            }
            // Pre-warm pagecache only when explicitly requested via
            // `dazzle.bench.prewarm=true`. By default skip — on EMUI 9
            // / Kirin 659 even reading 468 MB into pagecache pushes the
            // bench process into iAware's "memory hog" tier and the
            // subsequent LLM mmap triggers a kill. The default mmap
            // path with lazy fault-in (no pre-warm) keeps growth
            // gradual and slips under iAware's growth-rate detector.
            val prewarmProp = System.getProperty("dazzle.bench.prewarm")
            val skipPrewarm = prewarmProp == null ||
                !prewarmProp.startsWith("t", ignoreCase = true)
            if (!skipPrewarm) {
                try {
                    val t0 = System.nanoTime()
                    java.io.FileInputStream(smallSrc).use { fis ->
                        val buf = ByteArray(1 shl 20)
                        var total = 0L
                        while (true) { val n = fis.read(buf); if (n <= 0) break; total += n }
                        Log.i(TAG, "  pre-warmed ${total / (1024 * 1024)} MB in ${(System.nanoTime() - t0) / 1_000_000} ms")
                    }
                } catch (e: Throwable) { Log.w(TAG, "pre-warm small failed: ${e.message}") }
            } else {
                Log.i(TAG, "  skipping pre-warm (use_mmap=false → read() into anon)")
            }
            val small = DazzleLlm.open(
                context, smallSrc.absolutePath,
                nCtx = cfg.llmNCtx,
                nBatch = cfg.llmNBatch,
                kvCacheType = cfg.llmKvCacheType,
                flashAttention = cfg.flashAttention,
                useMlock = cfg.useMlock,
            )
            val variantA = try {
                runVariantRag(small, queryEmbeddings, queryEmbedUs, index, queries, passageById, cfg)
            } catch (e: Throwable) {
                Log.e(TAG, "variant A failed", e); null
            } ?: emptyMap()

            // ── Variant C: small + no-RAG ────────────────────────────────
            // Closes the 2x2 matrix on the small-model row. Re-uses the
            // already-open small LLM so we don't pay the 380 MB model
            // load twice.
            Log.i(TAG, "── variant C: small + no-RAG (${cfg.smallLlmFile}) ──")
            val variantC = try {
                runVariantNoRag(small, queries, passageById, cfg)
            } catch (e: Throwable) {
                Log.e(TAG, "variant C failed", e); null
            } ?: emptyMap()
            small.close()

            // ── Variant B: large + no-RAG ────────────────────────────────
            Log.i(TAG, "── variant B: large + no-RAG (${cfg.largeLlmFile}) ──")
            try {
                System.gc(); System.runFinalization(); Thread.sleep(500)
                if (!skipPrewarm) {
                    val t0 = System.nanoTime()
                    java.io.FileInputStream(largeSrc).use { fis ->
                        val buf = ByteArray(1 shl 20)
                        var total = 0L
                        while (true) { val n = fis.read(buf); if (n <= 0) break; total += n }
                        Log.i(TAG, "  pre-warmed large ${total / (1024 * 1024)} MB in ${(System.nanoTime() - t0) / 1_000_000} ms")
                    }
                }
            } catch (e: Throwable) { Log.w(TAG, "pre-warm large failed: ${e.message}") }
            val large = DazzleLlm.open(
                context, largeSrc.absolutePath,
                nCtx = cfg.llmNCtx,
                nBatch = cfg.llmNBatch,
                kvCacheType = cfg.llmKvCacheType,
                flashAttention = cfg.flashAttention,
                useMlock = cfg.useMlock,
            )
            val variantB = try {
                runVariantNoRag(large, queries, passageById, cfg)
            } catch (e: Throwable) {
                Log.e(TAG, "variant B failed", e); null
            } ?: emptyMap()

            // ── Variant D: large + RAG ───────────────────────────────────
            // Closes the 2x2 matrix on the large-model row. The
            // retrieval step is identical to variant A; only the LLM
            // generating the answer is different.
            Log.i(TAG, "── variant D: large + RAG (${cfg.largeLlmFile}) ──")
            val variantD = try {
                runVariantRag(large, queryEmbeddings, queryEmbedUs, index, queries, passageById, cfg)
            } catch (e: Throwable) {
                Log.e(TAG, "variant D failed", e); null
            } ?: emptyMap()
            large.close()

            result["variants"] = linkedMapOf(
                "small_rag"    to variantA,    // A: 0.5B + RAG (existing)
                "small_no_rag" to variantC,    // C: 0.5B no-RAG (new for 2x2)
                "large_no_rag" to variantB,    // B: 1.5B no-RAG (existing)
                "large_rag"    to variantD,    // D: 1.5B + RAG (new for 2x2)
            )
        } finally {
            if (!embedderClosed) {
                try { embedder.close() } catch (_: Throwable) {}
            }
        }
        return result
    }

    // ── Variants ─────────────────────────────────────────────────────────

    internal fun runVariantRag(
        llm: DazzleLlm,
        queryEmbeddings: Array<FloatArray>,
        precomputedEmbedUs: LongArray,
        index: VectorIndex,
        queries: List<Query>,
        passageById: Map<String, Passage>,
        cfg: Config,
    ): Map<String, Any?> {
        val embedUs   = precomputedEmbedUs.copyOf()
        val searchUs  = LongArray(queries.size)
        val prefillUs = LongArray(queries.size)
        val decodeUs  = LongArray(queries.size)
        val totalUs   = LongArray(queries.size)
        val pTokens   = IntArray (queries.size)
        val nTokens   = IntArray (queries.size)
        val f1s       = DoubleArray(queries.size)
        val ems       = DoubleArray(queries.size)
        val emsCt     = DoubleArray(queries.size)
        val f1sh      = DoubleArray(queries.size)
        val records   = ArrayList<Map<String, Any?>>(queries.size)

        for ((qi, q) in queries.withIndex()) {
            val tTotal = System.nanoTime()

            // Use the pre-computed query embedding so the embedder
            // can be released before the LLM phase. embedUs is the
            // measured cost from the precompute step (preserved verbatim
            // so the JSON metric semantics stay identical to v1).
            val qv = queryEmbeddings[qi]
            val t1 = System.nanoTime()
            val hits = index.searchDirect(qv, k = cfg.k, efRuntime = cfg.efRuntime)
            val t2 = System.nanoTime()
            searchUs[qi] = (t2 - t1) / 1_000L

            val retrieved = hits.mapNotNull { passageById[it.first] }
            val prompt = buildPromptWithPassages(q.text, retrieved)
            val answer = llm.generate(prompt, maxNewTokens = cfg.maxNewTokens)
            val total  = (System.nanoTime() - tTotal) / 1_000L

            prefillUs[qi] = llm.lastPrefillUs()
            decodeUs [qi] = llm.lastDecodeUs()
            pTokens  [qi] = llm.lastPromptTokens()
            nTokens  [qi] = llm.lastNewTokens()
            totalUs  [qi] = total

            val goldPassageText = q.gold.firstNotNullOfOrNull {
                passageById[cfg.hashPrefix + it]?.text
            }.orEmpty()
            val span = extractAnswerSpan(answer)
            f1s  [qi] = tokenF1(answer, goldPassageText)
            ems  [qi] = emStrict(span, q.shortAnswers)
            emsCt[qi] = emContains(answer, q.shortAnswers)
            f1sh [qi] = f1Short(span, q.shortAnswers)

            if (qi % 5 == 0) {
                Log.i(TAG, "  A[$qi/${queries.size}] total=${total}us " +
                    "prefill=${prefillUs[qi]}us decode=${decodeUs[qi]}us " +
                    "ptok=${pTokens[qi]} ntok=${nTokens[qi]} " +
                    "em=${if (ems[qi].isNaN()) "-" else "%.0f".format(ems[qi])} " +
                    "ct=${if (emsCt[qi].isNaN()) "-" else "%.0f".format(emsCt[qi])} " +
                    "f1s=${if (f1sh[qi].isNaN()) "-" else "%.2f".format(f1sh[qi])}")
            }
            records += linkedMapOf(
                "qid"           to q.id,
                "answer"        to answer,
                "answer_span"   to span,
                "short_answers" to q.shortAnswers,
                "em_short"      to ems[qi].takeUnless { it.isNaN() },
                "em_contains"   to emsCt[qi].takeUnless { it.isNaN() },
                "f1_short"      to f1sh[qi].takeUnless { it.isNaN() },
                "f1_passage"    to f1s[qi],
                // Per-query raw latency / token counts so a chunked run
                // (Kirin 659 multi-process driver) can reconstruct stats
                // post-hoc from the union of per-chunk records without
                // needing chunk-level arrays.
                "embed_us"      to embedUs[qi],
                "search_us"     to searchUs[qi],
                "prefill_us"    to prefillUs[qi],
                "decode_us"     to decodeUs[qi],
                "total_us"      to totalUs[qi],
                "prompt_tokens" to pTokens[qi],
                "new_tokens"    to nTokens[qi],
            )
        }

        return linkedMapOf(
            "embed_us"      to latencyStats(embedUs),
            "search_us"     to latencyStats(searchUs),
            "prefill_us"    to latencyStats(prefillUs),
            "decode_us"     to latencyStats(decodeUs),
            "total_us"      to latencyStats(totalUs),
            "prompt_tokens" to intStats(pTokens),
            "new_tokens"    to intStats(nTokens),
            "em_short"      to doubleStats(ems),
            "em_contains"   to doubleStats(emsCt),
            "f1_short"      to doubleStats(f1sh),
            "token_f1_vs_gold_passage" to doubleStats(f1s),
            "examples"      to records,
        )
    }

    internal fun runVariantNoRag(
        llm: DazzleLlm,
        queries: List<Query>,
        passageById: Map<String, Passage>,
        cfg: Config,
    ): Map<String, Any?> {
        val prefillUs = LongArray(queries.size)
        val decodeUs  = LongArray(queries.size)
        val totalUs   = LongArray(queries.size)
        val pTokens   = IntArray (queries.size)
        val nTokens   = IntArray (queries.size)
        val f1s       = DoubleArray(queries.size)
        val ems       = DoubleArray(queries.size)
        val emsCt     = DoubleArray(queries.size)
        val f1sh      = DoubleArray(queries.size)
        val records   = ArrayList<Map<String, Any?>>(queries.size)

        for ((qi, q) in queries.withIndex()) {
            val tTotal = System.nanoTime()
            val prompt = buildPromptNoContext(q.text)
            val answer = llm.generate(prompt, maxNewTokens = cfg.maxNewTokens)
            val total  = (System.nanoTime() - tTotal) / 1_000L

            prefillUs[qi] = llm.lastPrefillUs()
            decodeUs [qi] = llm.lastDecodeUs()
            pTokens  [qi] = llm.lastPromptTokens()
            nTokens  [qi] = llm.lastNewTokens()
            totalUs  [qi] = total

            val goldPassageText = q.gold.firstNotNullOfOrNull {
                passageById[cfg.hashPrefix + it]?.text
            }.orEmpty()
            val span = extractAnswerSpan(answer)
            f1s  [qi] = tokenF1(answer, goldPassageText)
            ems  [qi] = emStrict(span, q.shortAnswers)
            emsCt[qi] = emContains(answer, q.shortAnswers)
            f1sh [qi] = f1Short(span, q.shortAnswers)

            if (qi % 5 == 0) {
                Log.i(TAG, "  B[$qi/${queries.size}] total=${total}us " +
                    "prefill=${prefillUs[qi]}us decode=${decodeUs[qi]}us " +
                    "ptok=${pTokens[qi]} ntok=${nTokens[qi]} " +
                    "em=${if (ems[qi].isNaN()) "-" else "%.0f".format(ems[qi])} " +
                    "ct=${if (emsCt[qi].isNaN()) "-" else "%.0f".format(emsCt[qi])} " +
                    "f1s=${if (f1sh[qi].isNaN()) "-" else "%.2f".format(f1sh[qi])}")
            }
            records += linkedMapOf(
                "qid"           to q.id,
                "answer"        to answer,
                "answer_span"   to span,
                "short_answers" to q.shortAnswers,
                "em_short"      to ems[qi].takeUnless { it.isNaN() },
                "em_contains"   to emsCt[qi].takeUnless { it.isNaN() },
                "f1_short"      to f1sh[qi].takeUnless { it.isNaN() },
                "f1_passage"    to f1s[qi],
                "prefill_us"    to prefillUs[qi],
                "decode_us"     to decodeUs[qi],
                "total_us"      to totalUs[qi],
                "prompt_tokens" to pTokens[qi],
                "new_tokens"    to nTokens[qi],
            )
        }

        return linkedMapOf(
            "embed_us"      to emptyMap<String, Any?>(),
            "search_us"     to emptyMap<String, Any?>(),
            "prefill_us"    to latencyStats(prefillUs),
            "decode_us"     to latencyStats(decodeUs),
            "total_us"      to latencyStats(totalUs),
            "prompt_tokens" to intStats(pTokens),
            "new_tokens"    to intStats(nTokens),
            "em_short"      to doubleStats(ems),
            "em_contains"   to doubleStats(emsCt),
            "f1_short"      to doubleStats(f1sh),
            "token_f1_vs_gold_passage" to doubleStats(f1s),
            "examples"      to records,
        )
    }

    // ── Prompt builders ──────────────────────────────────────────────────
    //
    // We stay model-agnostic — a plain instruction prompt works on Qwen,
    // Llama, Gemma and Phi without chat-template juggling. The SDK can
    // add template-aware builders later when we ship more formal eval.

    private fun buildPromptWithPassages(question: String, passages: List<Passage>): String {
        val sb = StringBuilder()
        sb.append("Answer the question using only the context below. ")
        sb.append("Reply with a short factual answer (one phrase).\n\n")
        sb.append("Context:\n")
        for ((i, p) in passages.withIndex()) {
            sb.append('[').append(i + 1).append("] ")
            sb.append(p.text.take(500))
            sb.append('\n')
        }
        sb.append("\nQuestion: ").append(question).append('\n')
        sb.append("Answer:")
        return sb.toString()
    }

    private fun buildPromptNoContext(question: String): String =
        "Answer the question with a short factual phrase (one line).\n" +
            "Question: $question\nAnswer:"

    // ── Slice I/O ────────────────────────────────────────────────────────

    internal fun loadPassages(context: Context, asset: String): List<Passage> {
        val out = ArrayList<Passage>(4096)
        context.assets.open(asset).use { s ->
            BufferedReader(InputStreamReader(s, Charsets.UTF_8)).useLines { lines ->
                for (line in lines) {
                    if (line.isBlank()) continue
                    val j = JSONObject(line)
                    out += Passage(j.getString("_id"), j.getString("text"))
                }
            }
        }
        return out
    }

    internal fun loadQueries(context: Context, asset: String): List<Query> {
        val out = ArrayList<Query>(256)
        context.assets.open(asset).use { s ->
            BufferedReader(InputStreamReader(s, Charsets.UTF_8)).useLines { lines ->
                for (line in lines) {
                    if (line.isBlank()) continue
                    val j = JSONObject(line)
                    val gArr = j.optJSONArray("gold") ?: JSONArray()
                    val gold = ArrayList<String>(gArr.length())
                    for (i in 0 until gArr.length()) gold += gArr.getString(i)
                    val sArr = j.optJSONArray("short_answers") ?: JSONArray()
                    val shortAns = ArrayList<String>(sArr.length())
                    for (i in 0 until sArr.length()) shortAns += sArr.getString(i)
                    out += Query(j.getString("_id"), j.getString("text"), gold, shortAns)
                }
            }
        }
        return out
    }

    // ── Scoring ──────────────────────────────────────────────────────────
    //
    // SQuAD/NQ-open style normalisation: lowercase, strip punctuation +
    // articles, collapse whitespace. We score three short-answer metrics
    // plus a passage-level backup:
    //   - `em_short`     : strict exact match between the extracted answer
    //                      span and any alias (after normalisation).
    //   - `em_contains`  : 1.0 if any alias's normalised tokens appear
    //                      contiguously anywhere in the *full* output; laxer
    //                      diagnostic that disentangles "model knows" from
    //                      "model answers concisely".
    //   - `f1_short`     : max token-F1 between the extracted span and each
    //                      alias. By construction `em_short ≤ f1_short`;
    //                      `em_contains` is a separate signal, not a cap.
    // Span extraction is deliberately conservative: trim leading whitespace
    // and cut at the first `\n`, `Question:` or fresh `Answer:` (the prompt
    // already ends in `Answer:`, so a second occurrence is hallucinated
    // continuation). This matches how a downstream consumer of the model
    // would parse a one-line factoid answer.

    private val STOP = setOf("a", "an", "the")
    private val punct = Regex("[\\p{Punct}]+")
    private val ws    = Regex("\\s+")

    private fun normalize(s: String): List<String> {
        val flat = punct.replace(s.lowercase(), " ")
        return ws.split(flat).filter { it.isNotBlank() && it !in STOP }
    }

    private fun extractAnswerSpan(raw: String): String {
        val s = raw.trimStart()
        var cut = s.length
        for (token in listOf("\n", "Question:", "Answer:")) {
            val i = s.indexOf(token)
            if (i in 0 until cut) cut = i
        }
        return s.substring(0, cut).trim()
    }

    private fun tokenF1Tokens(p: List<String>, g: List<String>): Double {
        if (p.isEmpty() || g.isEmpty()) return 0.0
        val pc = p.groupingBy { it }.eachCount().toMutableMap()
        var overlap = 0
        for (t in g) {
            val c = pc[t] ?: continue
            if (c > 0) { overlap++; pc[t] = c - 1 }
        }
        if (overlap == 0) return 0.0
        val precision = overlap.toDouble() / p.size
        val recall    = overlap.toDouble() / g.size
        return 2.0 * precision * recall / (precision + recall)
    }

    private fun tokenF1(pred: String, gold: String): Double =
        tokenF1Tokens(normalize(pred), normalize(gold))

    /** Strict EM: extracted span equals any alias after normalisation. */
    private fun emStrict(span: String, aliases: List<String>): Double {
        if (aliases.isEmpty()) return Double.NaN
        val p = normalize(span)
        for (a in aliases) {
            val g = normalize(a)
            if (g.isNotEmpty() && p == g) return 1.0
        }
        return 0.0
    }

    /** Lax EM: 1.0 if any alias's normalised tokens appear contiguously anywhere in pred. */
    private fun emContains(pred: String, aliases: List<String>): Double {
        if (aliases.isEmpty()) return Double.NaN
        val p = normalize(pred)
        if (p.isEmpty()) return 0.0
        for (a in aliases) {
            val g = normalize(a)
            if (g.isEmpty()) continue
            if (g.size > p.size) continue
            var i = 0
            while (i + g.size <= p.size) {
                var match = true
                for (j in g.indices) {
                    if (p[i + j] != g[j]) { match = false; break }
                }
                if (match) return 1.0
                i++
            }
        }
        return 0.0
    }

    /** Max token-F1 over aliases against the extracted span. NaN if no aliases. */
    private fun f1Short(span: String, aliases: List<String>): Double {
        if (aliases.isEmpty()) return Double.NaN
        val p = normalize(span)
        var best = 0.0
        for (a in aliases) {
            val f = tokenF1Tokens(p, normalize(a))
            if (f > best) best = f
        }
        return best
    }

    // ── Stats + metadata ─────────────────────────────────────────────────

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

    private fun intStats(vs: IntArray): Map<String, Any?> {
        if (vs.isEmpty()) return emptyMap()
        val sorted = vs.copyOf().also { it.sort() }
        fun pct(p: Double): Int = sorted[minOf((sorted.size * p).toInt(), sorted.size - 1)]
        return linkedMapOf(
            "n"   to sorted.size,
            "avg" to sorted.sum().toDouble() / sorted.size,
            "p50" to pct(0.50),
            "p95" to pct(0.95),
            "min" to sorted.first(),
            "max" to sorted.last(),
        )
    }

    private fun doubleStats(vs: DoubleArray): Map<String, Any?> {
        val filtered = vs.filter { !it.isNaN() }.toDoubleArray()
        if (filtered.isEmpty()) return emptyMap()
        val sorted = filtered.copyOf().also { it.sort() }
        fun pct(p: Double): Double = sorted[minOf((sorted.size * p).toInt(), sorted.size - 1)]
        return linkedMapOf(
            "n"   to sorted.size,
            "avg" to sorted.sum() / sorted.size,
            "p50" to pct(0.50),
            "p95" to pct(0.95),
            "min" to sorted.first(),
            "max" to sorted.last(),
        )
    }

    internal fun fileInfo(f: File, dim: Int?, nCtx: Int): Map<String, Any?> = linkedMapOf(
        "file"       to f.name,
        "size_bytes" to f.length(),
        "output_dim" to dim,
        "n_ctx"      to nCtx,
    )

    internal fun collectDeviceInfo(): Map<String, Any?> = linkedMapOf(
        "model"           to Build.MODEL,
        "manufacturer"    to Build.MANUFACTURER,
        "board"           to Build.BOARD,
        "abi"             to Build.SUPPORTED_ABIS.firstOrNull(),
        "android_version" to Build.VERSION.RELEASE,
        "sdk_int"         to Build.VERSION.SDK_INT,
        "cpu_cores"       to Runtime.getRuntime().availableProcessors(),
    )
}
