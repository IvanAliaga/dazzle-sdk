// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import android.content.Context
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
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * Multi-process driver for the §5.9 RAG E2E bench, written for chips
 * where a single-process run cannot reach the LLM phase because the
 * embed loop accumulates an iAware kill-score that fires the moment
 * the variant LLM is opened (Kirin 659 / EMUI 9).
 *
 * The bench is sliced into four `am instrument` invocations:
 *
 *   phase=embed    → embed all passages + queries, build a FLAT index
 *                    snapshot, persist `passage_embeds.bin`,
 *                    `query_embeds.bin`, `queries.json`,
 *                    `passages.json`, `meta.json`, `query_embed_us.bin`
 *                    to the cache dir, then exit. No LLM is loaded.
 *   phase=small    → fresh process. Reads the cache, rebuilds the
 *                    FLAT index in <1 s, opens Qwen 0.5B once, runs
 *                    variants A (+RAG) and C (no-RAG) back-to-back,
 *                    writes `partial_small.json`, exits.
 *   phase=large    → fresh process. Same as `small` but with Qwen 1.5B
 *                    and variants B (no-RAG) + D (+RAG). Writes
 *                    `partial_large.json`.
 *   phase=merge    → reads both partials + meta, writes the canonical
 *                    `rag_e2e_<small_model>_<TS>.json` to
 *                    `/sdcard/Documents/`. No LLM, no cache.
 *
 * Each phase is a separate process so iAware's per-process kill-score
 * resets between phases. The full bench survives on a chip that
 * cannot host even one variant in the original monolithic
 * `RagE2EBench.run` path.
 *
 * Cache lives at `/sdcard/Documents/rag_kirin_split/`. It is intentionally
 * persistent across runs — re-running `phase=small` after a kill picks
 * up the embed work without paying the 25 min penalty again.
 */
object RagE2EBenchPhases {

    private const val TAG = "RagE2EPhases"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    private fun ensureServerRunning(context: Context) {
        if (!DazzleServer.isRunning()) {
            DazzleServer.start(context, DazzleConfig(
                tcpEnabled = true,
                port = 6380,
                persistence = DazzlePersistence.None,
                wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
                // VectorSearch module must be explicitly loaded — without
                // it FT.CREATE has no handler and the per-index schema
                // never lands in `g_indexes`, so the JNI-direct
                // `addBatchDirect` path returns silently with 0 vectors
                // indexed and `searchDirect` returns 0 hits. Reproduces
                // exactly the Kirin §5.9.5 prompt-token anomaly when this
                // line is missing.
                modules = setOf(DazzleModule.VectorSearch),
            ))
            Thread.sleep(800)
        }
    }

    private fun cacheDir(context: Context): File {
        // Prefer app-external (no scoped-storage gate) → fall back to
        // app-internal if the device has no external mount.
        val ext = context.getExternalFilesDir(null)
        val base = ext ?: context.filesDir
        val dir = File(base, "rag_kirin_split")
        if (!dir.exists() && !dir.mkdirs()) {
            // Last resort: cache dir always writable.
            val cd = File(context.cacheDir, "rag_kirin_split")
            cd.mkdirs()
            return cd
        }
        return dir
    }

    private fun writeFloatMatrix(file: File, matrix: Array<FloatArray>) {
        DataOutputStream(FileOutputStream(file).buffered()).use { out ->
            out.writeInt(matrix.size)
            val dim = if (matrix.isNotEmpty()) matrix[0].size else 0
            out.writeInt(dim)
            for (row in matrix) {
                require(row.size == dim) { "ragged matrix" }
                for (x in row) out.writeFloat(x)
            }
        }
    }

    private fun readFloatMatrix(file: File): Array<FloatArray> {
        DataInputStream(FileInputStream(file).buffered()).use { ins ->
            val n = ins.readInt()
            val d = ins.readInt()
            return Array(n) {
                FloatArray(d).also { row ->
                    for (i in 0 until d) row[i] = ins.readFloat()
                }
            }
        }
    }

    private fun writeLongs(file: File, vs: LongArray) {
        DataOutputStream(FileOutputStream(file).buffered()).use { out ->
            out.writeInt(vs.size)
            for (v in vs) out.writeLong(v)
        }
    }

    private fun readLongs(file: File): LongArray {
        DataInputStream(FileInputStream(file).buffered()).use { ins ->
            val n = ins.readInt()
            return LongArray(n) { ins.readLong() }
        }
    }

    private fun writeQueries(file: File, queries: List<RagE2EBench.Query>) {
        val arr = JSONArray()
        for (q in queries) {
            val obj = JSONObject()
            obj.put("id", q.id)
            obj.put("text", q.text)
            obj.put("gold", JSONArray(q.gold))
            obj.put("short_answers", JSONArray(q.shortAnswers))
            arr.put(obj)
        }
        file.writeText(arr.toString())
    }

    private fun readQueries(file: File): List<RagE2EBench.Query> {
        val arr = JSONArray(file.readText())
        val out = ArrayList<RagE2EBench.Query>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val gold = o.getJSONArray("gold").let { ja ->
                List(ja.length()) { ja.getString(it) }
            }
            val shorts = o.getJSONArray("short_answers").let { ja ->
                List(ja.length()) { ja.getString(it) }
            }
            out.add(RagE2EBench.Query(
                id = o.getString("id"),
                text = o.getString("text"),
                gold = gold,
                shortAnswers = shorts,
            ))
        }
        return out
    }

    private fun writePassages(file: File, passages: List<RagE2EBench.Passage>) {
        val arr = JSONArray()
        for (p in passages) {
            val obj = JSONObject()
            obj.put("id", p.id)
            obj.put("text", p.text)
            arr.put(obj)
        }
        file.writeText(arr.toString())
    }

    private fun readPassages(file: File): List<RagE2EBench.Passage> {
        val arr = JSONArray(file.readText())
        return List(arr.length()) {
            val o = arr.getJSONObject(it)
            RagE2EBench.Passage(o.getString("id"), o.getString("text"))
        }
    }

    private fun cfgFromSysProps(base: RagE2EBench.Config): RagE2EBench.Config {
        return base.copy(
            llmKvCacheType = System.getProperty("dazzle.bench.kv_cache")
                ?.let { runCatching { KvCacheType.valueOf(it) }.getOrNull() }
                ?: base.llmKvCacheType,
            flashAttention = System.getProperty("dazzle.bench.flash_attn")
                ?.toBooleanStrictOrNull()
                ?: base.flashAttention,
            useMlock = System.getProperty("dazzle.bench.use_mlock")
                ?.toBooleanStrictOrNull()
                ?: base.useMlock,
            nThreads = System.getProperty("dazzle.bench.n_threads")
                ?.toIntOrNull()
                ?: base.nThreads,
            llmNBatch = System.getProperty("dazzle.bench.llm_n_batch")
                ?.toIntOrNull()
                ?: base.llmNBatch,
            llmNCtx = System.getProperty("dazzle.bench.llm_n_ctx")
                ?.toIntOrNull()
                ?: base.llmNCtx,
            algorithm = System.getProperty("dazzle.bench.algo")
                ?.let { runCatching { VectorIndex.Algorithm.valueOf(it) }.getOrNull() }
                ?: base.algorithm,
            maxQueries = System.getProperty("dazzle.bench.max_queries")
                ?.toIntOrNull()
                ?: base.maxQueries,
        )
    }

    /** Phase 1 — embed everything, persist binaries, exit clean. */
    fun runEmbedPhase(context: Context) {
        val cfg = cfgFromSysProps(RagE2EBench.Config())
        val dir = cacheDir(context)
        Log.i(TAG, "embed phase → cache dir ${dir.absolutePath}")

        fun resolveWeight(name: String, subdir: String): File {
            val candidates = listOf(
                File(File(context.filesDir, subdir), name),
                File(File(context.getExternalFilesDir(null), subdir), name),
                File(Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS), name),
            )
            return candidates.firstOrNull { it.exists() }
                ?: error("GGUF $name not found in any candidate path")
        }

        val embedSrc = resolveWeight(cfg.embedFile, "embed")

        val embedder = DazzleEmbedder.open(
            context, embedSrc.absolutePath,
            nCtx = cfg.embedNCtx,
            nBatch = cfg.embedNBatch,
            flashAttention = cfg.flashAttention,
            useMlock = cfg.useMlock,
            nThreads = if (cfg.nThreads > 0) cfg.nThreads
                       else Runtime.getRuntime().availableProcessors().coerceAtMost(4),
        )
        Log.i(TAG, "embedder open: dim=${embedder.outputDim}")

        val passagesAll = RagE2EBench.loadPassages(context, cfg.passagesAsset)
        val queriesAll = RagE2EBench.loadQueries(context, cfg.queriesAsset)
        val queries = cfg.maxQueries?.let { queriesAll.take(it) } ?: queriesAll
        Log.i(TAG, "slice: ${passagesAll.size} passages, ${queries.size} queries")

        // Embed passages
        val passageEmbeds = Array(passagesAll.size) { i ->
            val t0 = System.nanoTime()
            val v = embedder.embed(passagesAll[i].text)
            val tMs = (System.nanoTime() - t0) / 1_000_000L
            if (i < 5 || i >= passagesAll.size - 5 || i % 200 == 0) {
                Log.i(TAG, "  embed passage $i/${passagesAll.size} took=${tMs}ms")
            }
            v
        }

        // Embed queries
        val queryEmbedUs = LongArray(queries.size)
        val queryEmbeds = Array(queries.size) { qi ->
            val tq0 = System.nanoTime()
            val v = embedder.embed(queries[qi].text)
            queryEmbedUs[qi] = (System.nanoTime() - tq0) / 1_000L
            if (qi % 50 == 0) Log.i(TAG, "  embed query $qi/${queries.size}")
            v
        }
        embedder.close()

        // Persist
        writeFloatMatrix(File(dir, "passage_embeds.bin"), passageEmbeds)
        writeFloatMatrix(File(dir, "query_embeds.bin"), queryEmbeds)
        writeLongs(File(dir, "query_embed_us.bin"), queryEmbedUs)
        writeQueries(File(dir, "queries.json"), queries)
        writePassages(File(dir, "passages.json"), passagesAll)

        // Meta
        val meta = JSONObject()
        meta.put("dim", passageEmbeds[0].size)
        meta.put("n_passages", passagesAll.size)
        meta.put("n_queries", queries.size)
        meta.put("hash_prefix", cfg.hashPrefix)
        meta.put("k", cfg.k)
        meta.put("ef_runtime", cfg.efRuntime)
        meta.put("ef_construction", cfg.efConstruction)
        meta.put("algorithm", cfg.algorithm.name)
        meta.put("max_new_tokens", cfg.maxNewTokens)
        meta.put("embed_n_ctx", cfg.embedNCtx)
        meta.put("embed_n_batch", cfg.embedNBatch)
        meta.put("llm_n_ctx", cfg.llmNCtx)
        meta.put("llm_n_batch", cfg.llmNBatch)
        meta.put("llm_kv_cache", cfg.llmKvCacheType.name)
        meta.put("flash_attn", cfg.flashAttention)
        meta.put("use_mlock", cfg.useMlock)
        meta.put("n_threads", cfg.nThreads)
        meta.put("small_llm_file", cfg.smallLlmFile)
        meta.put("large_llm_file", cfg.largeLlmFile)
        meta.put("embed_file", cfg.embedFile)
        meta.put("device", JSONObject(RagE2EBench.collectDeviceInfo()))
        meta.put("models", JSONObject(linkedMapOf(
            "embedder"  to RagE2EBench.fileInfo(embedSrc, passageEmbeds[0].size, cfg.embedNCtx),
            "small_llm" to RagE2EBench.fileInfo(resolveWeight(cfg.smallLlmFile, "gen"), null, cfg.llmNCtx),
            "large_llm" to RagE2EBench.fileInfo(resolveWeight(cfg.largeLlmFile, "gen"), null, cfg.llmNCtx),
        )))
        File(dir, "meta.json").writeText(meta.toString(2))

        Log.i(TAG, "embed phase complete — cache at ${dir.absolutePath}")
    }

    /** Phase 2 — open one LLM, run two variants, persist partial JSON. */
    private fun runVariantsPhase(
        context: Context,
        which: String, // "small" or "large"
    ) {
        val cfg = cfgFromSysProps(RagE2EBench.Config())
        val dir = cacheDir(context)

        // Load cache
        val passages = readPassages(File(dir, "passages.json"))
        val queries = readQueries(File(dir, "queries.json"))
        val passageEmbeds = readFloatMatrix(File(dir, "passage_embeds.bin"))
        val queryEmbeds = readFloatMatrix(File(dir, "query_embeds.bin"))
        val queryEmbedUs = readLongs(File(dir, "query_embed_us.bin"))
        val passageById = passages.associateBy { cfg.hashPrefix + it.id }
        Log.i(TAG, "$which phase: cache loaded N=${passageEmbeds.size} dim=${passageEmbeds[0].size} Q=${queryEmbeds.size}")

        // Build vector index from cached embeddings — fast (FLAT 50ms, HNSW few s)
        ensureServerRunning(context)
        val dazzle = DazzleServer.client()
        val index = dazzle.vectorIndex(
            name            = cfg.indexName,
            hashPrefix      = cfg.hashPrefix,
            vectorField     = "emb",
            dim             = passageEmbeds[0].size,
            algorithm       = cfg.algorithm,
            metric          = VectorIndex.Metric.COSINE,
            initialCapacity = passages.size,
            m               = 16,
            efConstruction  = cfg.efConstruction,
        )
        index.create()
        val ids = Array(passages.size) { cfg.hashPrefix + passages[it].id }
        val tBatch0 = System.nanoTime()
        index.addBatchDirect(ids, passageEmbeds)
        Log.i(TAG, "$which: addBatchDirect ${ids.size} vecs in ${(System.nanoTime() - tBatch0) / 1_000_000L}ms")

        // Optional native env-var pass-through
        System.getProperty("dazzle.bench.use_mmap")?.let { v ->
            try {
                android.system.Os.setenv("DAZZLE_LLAMA_USE_MMAP", v, true)
                Log.i(TAG, "$which: DAZZLE_LLAMA_USE_MMAP=$v")
            } catch (_: Throwable) {}
        }

        // Resolve LLM path
        fun resolveWeight(name: String, subdir: String): File {
            val candidates = listOf(
                File(File(context.filesDir, subdir), name),
                File(File(context.getExternalFilesDir(null), subdir), name),
                File(Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS), name),
            )
            return candidates.firstOrNull { it.exists() }
                ?: error("GGUF $name not found")
        }
        val (llmFile, ragName, noRagName) = when (which) {
            "small" -> Triple(cfg.smallLlmFile, "small_rag", "small_no_rag")
            "large" -> Triple(cfg.largeLlmFile, "large_rag", "large_no_rag")
            else -> error("unknown phase: $which")
        }
        val llmSrc = resolveWeight(llmFile, "gen")

        Log.i(TAG, "$which: opening $llmFile")
        val tOpen0 = System.nanoTime()
        val llm = DazzleLlm.open(
            context, llmSrc.absolutePath,
            nCtx = cfg.llmNCtx,
            nBatch = cfg.llmNBatch,
            kvCacheType = cfg.llmKvCacheType,
            flashAttention = cfg.flashAttention,
            useMlock = cfg.useMlock,
        )
        Log.i(TAG, "$which: LLM opened in ${(System.nanoTime() - tOpen0) / 1_000_000L}ms")

        // Variant 1 (RAG)
        Log.i(TAG, "$which: starting +RAG variant ($ragName)")
        val variantRag = try {
            RagE2EBench.runVariantRag(llm, queryEmbeds, queryEmbedUs, index, queries, passageById, cfg)
        } catch (e: Throwable) {
            Log.e(TAG, "$which: +RAG variant failed", e); emptyMap()
        }

        // Variant 2 (no-RAG)
        Log.i(TAG, "$which: starting no-RAG variant ($noRagName)")
        val variantNoRag = try {
            RagE2EBench.runVariantNoRag(llm, queries, passageById, cfg)
        } catch (e: Throwable) {
            Log.e(TAG, "$which: no-RAG variant failed", e); emptyMap()
        }
        llm.close()

        // Persist partial
        val partial = JSONObject()
        partial.put(ragName, JSONObject(variantRag))
        partial.put(noRagName, JSONObject(variantNoRag))
        File(dir, "partial_$which.json").writeText(partial.toString(2))
        Log.i(TAG, "$which phase complete → partial_$which.json")
    }

    fun runSmallPhase(context: Context) = runVariantsPhase(context, "small")
    fun runLargePhase(context: Context) = runVariantsPhase(context, "large")

    /**
     * Chunked single-variant phase. Each invocation runs ONE variant for
     * a slice of queries [q_offset .. q_offset + q_limit). Required on
     * Kirin 659 + Qwen 1.5B where iAware kills the bench process around
     * query 30/200 — splitting variant D into 4 chunks of 50 queries
     * (each in a fresh `am instrument` process) sidesteps the kill-score
     * accumulation. Each chunk writes
     * `partial_chunk_<variant>_<offset>.json`. The merge phase globs
     * these and recomputes the per-variant stats from the union of
     * per-chunk records (latency / token counts are persisted per query
     * in `examples[]` so the merge does not need chunk-level arrays).
     */
    fun runVariantChunk(context: Context, variantName: String) {
        val cfg = cfgFromSysProps(RagE2EBench.Config())
        val dir = cacheDir(context)
        val passages = readPassages(File(dir, "passages.json"))
        val queriesAll = readQueries(File(dir, "queries.json"))
        val passageEmbedsAll = readFloatMatrix(File(dir, "passage_embeds.bin"))
        val queryEmbedsAll = readFloatMatrix(File(dir, "query_embeds.bin"))
        val queryEmbedUsAll = readLongs(File(dir, "query_embed_us.bin"))
        val passageById = passages.associateBy { cfg.hashPrefix + it.id }

        val qOffset = (System.getProperty("dazzle.bench.q_offset")
            ?.toIntOrNull() ?: 0).coerceAtLeast(0)
        val qLimit = (System.getProperty("dazzle.bench.q_limit")
            ?.toIntOrNull() ?: queriesAll.size)
        val qEnd = (qOffset + qLimit).coerceAtMost(queriesAll.size)
        val querySlice = queriesAll.subList(qOffset, qEnd)
        val queryEmbedsSlice = Array(qEnd - qOffset) { queryEmbedsAll[qOffset + it] }
        val queryEmbedUsSlice = LongArray(qEnd - qOffset) { queryEmbedUsAll[qOffset + it] }
        Log.i(TAG, "chunk $variantName q[$qOffset..$qEnd) of ${queriesAll.size} (n=${querySlice.size})")

        ensureServerRunning(context)
        val dazzle = DazzleServer.client()
        val index = dazzle.vectorIndex(
            name            = cfg.indexName,
            hashPrefix      = cfg.hashPrefix,
            vectorField     = "emb",
            dim             = passageEmbedsAll[0].size,
            algorithm       = cfg.algorithm,
            metric          = VectorIndex.Metric.COSINE,
            initialCapacity = passages.size,
            m               = 16,
            efConstruction  = cfg.efConstruction,
        )
        index.create()
        val ids = Array(passages.size) { cfg.hashPrefix + passages[it].id }
        index.addBatchDirect(ids, passageEmbedsAll)

        // Resolve LLM path
        fun resolveWeight(name: String, subdir: String): File {
            val candidates = listOf(
                File(File(context.filesDir, subdir), name),
                File(File(context.getExternalFilesDir(null), subdir), name),
                File(Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS), name),
            )
            return candidates.firstOrNull { it.exists() }
                ?: error("GGUF $name not found")
        }
        val (llmFile, isRag) = when (variantName) {
            "small_rag"    -> Pair(cfg.smallLlmFile, true)
            "small_no_rag" -> Pair(cfg.smallLlmFile, false)
            "large_rag"    -> Pair(cfg.largeLlmFile, true)
            "large_no_rag" -> Pair(cfg.largeLlmFile, false)
            else -> error("unknown variant: $variantName")
        }
        val llmSrc = resolveWeight(llmFile, "gen")
        Log.i(TAG, "chunk $variantName: opening $llmFile")
        val llm = DazzleLlm.open(
            context, llmSrc.absolutePath,
            nCtx = cfg.llmNCtx,
            nBatch = cfg.llmNBatch,
            kvCacheType = cfg.llmKvCacheType,
            flashAttention = cfg.flashAttention,
            useMlock = cfg.useMlock,
        )
        Log.i(TAG, "chunk $variantName: starting variant on slice")
        val result = if (isRag) {
            RagE2EBench.runVariantRag(llm, queryEmbedsSlice, queryEmbedUsSlice, index, querySlice, passageById, cfg)
        } else {
            RagE2EBench.runVariantNoRag(llm, querySlice, passageById, cfg)
        }
        llm.close()

        val outFile = File(dir, "partial_chunk_${variantName}_${qOffset}.json")
        outFile.writeText(JSONObject(result).toString(2))
        Log.i(TAG, "chunk $variantName q$qOffset complete → ${outFile.name}")
    }

    /** Phase 4 — merge partials into the canonical bench JSON. */
    fun runMergePhase(context: Context) {
        val dir = cacheDir(context)
        val meta = JSONObject(File(dir, "meta.json").readText())

        val result = linkedMapOf<String, Any?>(
            "type"      to "rag_e2e",
            "timestamp" to java.time.Instant.now().toString(),
            "device"    to meta.getJSONObject("device").let { jsonToMap(it) },
            "models"    to jsonToMap(meta.getJSONObject("models")),
            "slice"     to linkedMapOf(
                "n_passages" to meta.getInt("n_passages"),
                "n_queries"  to meta.getInt("n_queries"),
            ),
            "config" to linkedMapOf(
                "k"               to meta.getInt("k"),
                "ef_runtime"      to meta.getInt("ef_runtime"),
                "ef_construction" to meta.getInt("ef_construction"),
                "algorithm"       to meta.getString("algorithm"),
                "max_new_tokens"  to meta.getInt("max_new_tokens"),
                "decoding"        to "greedy",
                "embed_n_ctx"     to meta.getInt("embed_n_ctx"),
                "embed_n_batch"   to meta.getInt("embed_n_batch"),
                "llm_n_ctx"       to meta.getInt("llm_n_ctx"),
                "llm_n_batch"     to meta.getInt("llm_n_batch"),
                "llm_kv_cache"    to meta.getString("llm_kv_cache"),
                "flash_attn"      to meta.getBoolean("flash_attn"),
                "use_mlock"       to meta.getBoolean("use_mlock"),
                "n_threads"       to meta.getInt("n_threads"),
                "split_phase_run" to true,
            ),
        )

        val variants = linkedMapOf<String, Any?>()
        for (which in listOf("small", "large")) {
            val pf = File(dir, "partial_$which.json")
            if (!pf.exists()) {
                Log.w(TAG, "merge: partial_$which.json missing — variant cells will be empty")
                continue
            }
            val partial = JSONObject(pf.readText())
            val keys = partial.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                variants[k] = jsonToMap(partial.getJSONObject(k))
            }
        }
        // Also fold in any per-variant chunked partials. A chunk file is
        // `partial_chunk_<variantName>_<qOffset>.json`; multiple chunks
        // for the same variantName are concatenated by qid order and the
        // per-variant stats are recomputed from the union of records.
        val chunkFiles = (dir.listFiles() ?: emptyArray())
            .filter { it.name.startsWith("partial_chunk_") && it.name.endsWith(".json") }
        if (chunkFiles.isNotEmpty()) {
            val byVariant = chunkFiles.groupBy { f ->
                // partial_chunk_<variantName>_<qOffset>.json
                val stem = f.name.removePrefix("partial_chunk_").removeSuffix(".json")
                stem.substringBeforeLast('_')
            }
            for ((variantName, files) in byVariant) {
                val sorted = files.sortedBy { f ->
                    f.name.removeSuffix(".json").substringAfterLast('_').toIntOrNull() ?: 0
                }
                val mergedRecords = mutableListOf<Map<String, Any?>>()
                for (cf in sorted) {
                    val co = JSONObject(cf.readText())
                    val ex = co.optJSONArray("examples") ?: continue
                    for (i in 0 until ex.length()) {
                        mergedRecords += jsonToMap(ex.getJSONObject(i))
                    }
                }
                if (mergedRecords.isEmpty()) continue
                val cell = recomputeVariantStats(mergedRecords)
                variants[variantName] = cell
                Log.i(TAG, "merge: variant $variantName from ${files.size} chunks (n=${mergedRecords.size})")
            }
        }
        result["variants"] = variants

        // /sdcard/Documents/ is scoped-storage-locked on targetSdk≥30; write
        // to the app-external dir which is always writable, and the operator
        // pulls via adb. The file name still encodes the small-LLM tag and
        // a wall-clock millis stamp so cross-platform aggregation can pick
        // it up unchanged.
        val docs = context.getExternalFilesDir(null) ?: context.filesDir
        docs.mkdirs()
        val ts = System.currentTimeMillis()
        val tag = meta.optString("small_llm_file", "qwen2.5_0.5b")
            .substringBefore(".gguf").replace("/", "_")
        val out = File(docs, "rag_e2e_${tag}_${ts}.json")
        out.writeText(gson.toJson(result))
        Log.i(TAG, "merge phase complete → ${out.absolutePath}")
    }

    private fun recomputeVariantStats(records: List<Map<String, Any?>>): Map<String, Any?> {
        fun longArrayOfField(key: String): LongArray = LongArray(records.size) { i ->
            (records[i][key] as? Number)?.toLong() ?: 0L
        }
        fun intArrayOfField(key: String): IntArray = IntArray(records.size) { i ->
            (records[i][key] as? Number)?.toInt() ?: 0
        }
        fun doubleArrayOfField(key: String): DoubleArray = DoubleArray(records.size) { i ->
            (records[i][key] as? Number)?.toDouble() ?: Double.NaN
        }
        fun statsLong(arr: LongArray): Map<String, Any?> {
            if (arr.isEmpty()) return linkedMapOf()
            val sorted = arr.sortedArray()
            fun pct(p: Double) = sorted[(p * (sorted.size - 1)).toInt().coerceIn(0, sorted.size - 1)]
            return linkedMapOf(
                "avg" to arr.average(),
                "p50" to pct(0.50),
                "p95" to pct(0.95),
                "min" to sorted.first(),
                "max" to sorted.last(),
            )
        }
        fun statsInt(arr: IntArray): Map<String, Any?> {
            if (arr.isEmpty()) return linkedMapOf()
            val sorted = arr.sortedArray()
            fun pct(p: Double) = sorted[(p * (sorted.size - 1)).toInt().coerceIn(0, sorted.size - 1)]
            return linkedMapOf(
                "avg" to arr.average(),
                "p50" to pct(0.50),
                "p95" to pct(0.95),
                "min" to sorted.first(),
                "max" to sorted.last(),
            )
        }
        fun statsDouble(arr: DoubleArray): Map<String, Any?> {
            val clean = arr.filter { !it.isNaN() }.toDoubleArray()
            if (clean.isEmpty()) return linkedMapOf("avg" to null, "n" to 0)
            return linkedMapOf(
                "avg" to clean.average(),
                "n"   to clean.size,
            )
        }
        return linkedMapOf(
            "embed_us"      to statsLong(longArrayOfField("embed_us")),
            "search_us"     to statsLong(longArrayOfField("search_us")),
            "prefill_us"    to statsLong(longArrayOfField("prefill_us")),
            "decode_us"     to statsLong(longArrayOfField("decode_us")),
            "total_us"      to statsLong(longArrayOfField("total_us")),
            "prompt_tokens" to statsInt(intArrayOfField("prompt_tokens")),
            "new_tokens"    to statsInt(intArrayOfField("new_tokens")),
            "em_short"      to statsDouble(doubleArrayOfField("em_short")),
            "em_contains"   to statsDouble(doubleArrayOfField("em_contains")),
            "f1_short"      to statsDouble(doubleArrayOfField("f1_short")),
            "token_f1_vs_gold_passage" to statsDouble(doubleArrayOfField("f1_passage")),
            "examples"      to records,
        )
    }

    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val map = linkedMapOf<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            map[k] = jsonToAny(obj.get(k))
        }
        return map
    }

    private fun jsonToAny(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonToMap(v)
        is JSONArray -> List(v.length()) { jsonToAny(v.get(it)) }
        else -> v
    }
}
