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
import java.io.File
import kotlin.random.Random

/**
 * Paired vector-search benchmark: dazzle-vector (HNSW) vs SQLite brute-force.
 *
 * For each (dim, N) configuration the harness generates the same random
 * corpus of FLOAT32 vectors, feeds it to both backends, then runs the same
 * query set on both. SQLite brute-force is exact, so its top-k is the ground
 * truth — HNSW recall@k is reported directly against it.
 *
 * HNSW is swept across `efRuntimes` to trace the recall/latency curve the
 * paper needs.
 *
 * Output: one JSON file per run under /sdcard/Documents/ (or filesDir
 * fallback) with every per-config measurement plus device metadata.
 *
 * Invoked from adb:
 *   adb shell am start -n dev.dazzle.experiment/.ExperimentActivity \
 *     --es backend vector-bench
 */
object VectorBenchmark {

    private const val TAG = "VecBench"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    data class Config(
        val dim: Int,
        val nDocs: Int,
        val nQueries: Int = 100,
        val k: Int = 10,
        val efRuntimes: IntArray = intArrayOf(10, 50, 100, 200),
        val seed: Long = 42L,
    )

    /** Default sweep: 3 dims × 3 scales, 9 configs total. */
    val DEFAULT_CONFIGS: List<Config> = listOf(
        Config(dim = 16,  nDocs = 500),
        Config(dim = 16,  nDocs = 2_000),
        Config(dim = 16,  nDocs = 10_000),
        Config(dim = 128, nDocs = 500),
        Config(dim = 128, nDocs = 2_000),
        Config(dim = 128, nDocs = 10_000),
        Config(dim = 384, nDocs = 500),
        Config(dim = 384, nDocs = 2_000),
        Config(dim = 384, nDocs = 10_000),
    )

    /** JNI hook into dazzle_jni.c — re-installs the SIGILL diagnostic
     *  handler that Valkey's `setupSignalHandlers()` overrides during
     *  server start. Called immediately before any Dazzle call so the
     *  diagnostic dump captures the faulting PC + opcode if SIGILL
     *  fires inside vector-search code (Cortex-A73 chip-compat work). */
    private external fun nInstallSigillHandler()

    fun run(context: Context, configs: List<Config> = DEFAULT_CONFIGS,
            forceSkipDazzle: Boolean = false) {
        Log.i(TAG, "══ VectorBenchmark: ${configs.size} configs ══")

        // Heartbeat thread — emits a Log.i every 5 s for the entire run.
        // ObjectBox ingest at N=20 000 takes 6-15 minutes during which the
        // bench thread is in native code with no Java logging; EMUI 10 /
        // iAware on Huawei treats that as "idle" and kills the foreground
        // activity ("app died, no saved state") despite the wakelock and
        // FLAG_KEEP_SCREEN_ON. The heartbeat keeps the app visibly active
        // from the system's POV. The thread is daemon so it does not
        // prevent process exit; it stops on its own when the bench loops
        // exit and the JVM tears down.
        val heartbeatRunning = java.util.concurrent.atomic.AtomicBoolean(true)
        val heartbeatStart = System.currentTimeMillis()
        val heartbeatThread = Thread({
            while (heartbeatRunning.get()) {
                try { Thread.sleep(5_000) } catch (_: InterruptedException) { return@Thread }
                val elapsed = (System.currentTimeMillis() - heartbeatStart) / 1000
                Log.i(TAG, "♥ heartbeat t=${elapsed}s")
            }
        }, "vecbench-heartbeat").apply { isDaemon = true; start() }

        val deviceInfo = collectDeviceInfo()
        val allResults = mutableListOf<Map<String, Any?>>()

        // CPU feature probe (informational).
        //
        // libvalkeysearch.so / simsimd_lib.c are compiled with
        // `-march=armv8-a` baseline (CMakeLists.txt:412-414) and the
        // C++ distance functions (`SimsimdCosI8Distance`,
        // `SimsimdDotF16Distance`, `SimsimdIPDistance`,
        // `SimsimdL2SqrDistance` in valkeysearch_module.cc) call simsimd's
        // **dispatched** entry points (`simsimd_cos_i8`, `simsimd_dot_f16`,
        // …) rather than the suffix-tagged direct variants. simsimd_lib.c
        // also enables `SIMSIMD_TARGET_NEON_F16 / NEON_I8 / NEON_BF16` so
        // the high-perf kernels are compiled in and selectable at runtime.
        // Net result: every Dazzle variant (HNSW, SQ8, F16, SQ8+Rerank)
        // is safe on every arm64-v8a chip in the paper's bench fleet
        // (Snapdragon 695, Snapdragon 662, Kirin 659, Kirin 710F).
        // We keep the probe as INFO so the resulting JSON is
        // self-documenting about whether the high-perf path was
        // available; we no longer use it to skip any engine.
        probeCpuFeatures()
        val skipDazzle = forceSkipDazzle
        val skipQuantizedDazzle = forceSkipDazzle
        if (forceSkipDazzle) {
            Log.w(TAG, "Dazzle engines force-skipped via launch flag (CPU not on the supported list)")
        }

        // Start the dazzle server with RDB persistence enabled so we can
        // BGSAVE between configs and measure the on-disk footprint of each
        // engine variant. Without RDB the dazzle rows in Table 11 sit at
        // "in-memory (no file)" and the SQLite peers can't be compared on
        // the same column. The wipeOnStart drops any leftover dump.rdb /
        // appendonlydir from previous runs so the footprint measurement
        // starts at a clean baseline.
        if (!skipDazzle) {
            if (DazzleServer.isRunning()) DazzleServer.stop()
            DazzleServer.start(context, DazzleConfig(
                port        = 6381,
                persistence = DazzlePersistence.Rdb(),
                wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
                modules     = setOf(DazzleModule.VectorSearch),
            ))
            Thread.sleep(600)
            // libdazzle.so is now loaded and Valkey's setupSignalHandlers()
            // has run; re-install our SIGILL diagnostic handler on top so
            // the next FT.CREATE / FT.SEARCH that traps captures PC + opcode
            // in logcat. Diagnostic only — no-op when nothing crashes.
            runCatching { nInstallSigillHandler() }
        }

        try {
            // Cold-start warmup: the very first FT.HADD / FT.SEARCH cycle on a
            // freshly-loaded valkeysearch module consistently shows degraded
            // recall (~0.3) that disappears on the next config. Run a tiny
            // throwaway config first so the real measurements start warm.
            Log.i(TAG, "── cold-start warmup (discarded) ──")
            runCatching {
                runOne(context, Config(dim = 8, nDocs = 32, nQueries = 10,
                                       k = 3, efRuntimes = intArrayOf(10)),
                       skipDazzle = skipDazzle,
                       skipQuantizedDazzle = skipQuantizedDazzle)
            }
            // Wipe everything the warmup populated so config-1's index is
            // truly the first hit on a clean keyspace. Without this the
            // warmup hashes (`vb:d8n32:0..31`) coexist with config-1's
            // `vb:d384n200:0..199` keys, and the cumulative state pulls
            // recall@k toward `N_cfg / N_total_so_far` (observed
            // 0.111 / 0.146 / 0.317 / 0.985 in the unfixed sweep).
            if (!skipDazzle) {
                runCatching { DazzleServer.directCommand("FLUSHALL") }
            }

            for (cfg in configs) {
                Log.i(TAG, "── cfg dim=${cfg.dim} N=${cfg.nDocs} ──")
                try {
                    val r = runOne(context, cfg,
                                   skipDazzle = skipDazzle,
                                   skipQuantizedDazzle = skipQuantizedDazzle)
                    allResults += r
                } catch (e: Throwable) {
                    Log.e(TAG, "cfg failed: ${e.message}", e)
                    allResults += mapOf(
                        "dim" to cfg.dim,
                        "n_docs" to cfg.nDocs,
                        "error" to (e.message ?: e.javaClass.simpleName),
                    )
                }
                // Drop ALL keys + indexes between configs. Without this the
                // dazzle index for config N+1 inherits hashes left over by
                // config N (different prefix but same RAM pool), which
                // skews the recall numerator. FLUSHALL is the cheapest way
                // to bring the server back to an empty keyspace short of
                // restarting it.
                if (!skipDazzle) {
                    runCatching { DazzleServer.directCommand("FLUSHALL") }
                }
            }
        } finally {
            if (!skipDazzle) {
                try { DazzleServer.stop() } catch (_: Throwable) {}
            }
        }

        // Stop the heartbeat now that the bench loops are done.
        heartbeatRunning.set(false)
        heartbeatThread.interrupt()

        val out = linkedMapOf<String, Any?>(
            "type" to "vector_benchmark",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to deviceInfo,
            "configs" to allResults,
        )

        val safeModel = Build.MODEL.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val ts = System.currentTimeMillis()
        val fname = "vecbench_${safeModel}_${ts}.json"
        val payload = gson.toJson(out)

        // Cascade of write targets — public Documents is preferred for
        // adb-pull convenience, but EMUI 10 + Android Q+ scoped storage
        // throws EACCES (Huawei FRL-L23 / Y9 2019 reproduces this). Fall
        // back to the app-private external dir (still pullable via run-as
        // / adb pull from /data/data/<pkg>/...) and finally filesDir.
        // The bench data must NEVER be silently lost: every fallback
        // path is logged + the function asserts at least one succeeded.
        val candidates: List<Pair<String, () -> File>> = listOf(
            "public Documents" to {
                val d = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
                d.mkdirs(); File(d, fname)
            },
            "app external files (Android/data)" to {
                val d = context.getExternalFilesDir(null) ?: context.filesDir
                d.mkdirs(); File(d, fname)
            },
            "internal filesDir" to {
                val d = context.filesDir
                d.mkdirs(); File(d, fname)
            },
        )
        var written: File? = null
        var lastErr: Throwable? = null
        for ((label, mk) in candidates) {
            try {
                val f = mk()
                f.writeText(payload)
                Log.i(TAG, "══ wrote ${f.absolutePath} (target: $label) ══")
                written = f
                break
            } catch (e: Throwable) {
                Log.w(TAG, "write to $label failed: ${e.message}")
                lastErr = e
            }
        }
        if (written == null) {
            Log.e(TAG, "ALL WRITE TARGETS FAILED — bench data lost", lastErr)
            throw IllegalStateException("vecbench: every output path was unwritable", lastErr)
        }
    }

    // ── Core per-config benchmark ────────────────────────────────────────────

    private fun runOne(context: Context, cfg: Config,
                       skipDazzle: Boolean = false,
                       skipQuantizedDazzle: Boolean = false): Map<String, Any?> {
        val rng = Random(cfg.seed)
        val docIds = Array(cfg.nDocs) { "doc:$it" }
        val docVecs = Array(cfg.nDocs) { FloatArray(cfg.dim) { rng.nextFloat() * 2f - 1f } }
        // Query set: sampled from corpus — using a hold-in sample is standard
        // for self-recall benchmarks and avoids needing a separate query set.
        val qIdxs = IntArray(cfg.nQueries) { rng.nextInt(cfg.nDocs) }

        // ── SQLite brute-force ───────────────────────────────────────────────
        // IMPORTANT: SQLite.addAll normalises the inputs in place, so we pass
        // deep copies to preserve the originals for the HNSW path and for the
        // query vectors (a normalised query against an un-normalised corpus
        // would break the recall comparison).
        val sqliteCopies = Array(cfg.nDocs) { docVecs[it].copyOf() }
        val sqlite = SqliteBruteforceVector(context, cfg.dim)
        sqlite.create()
        val sqIngestStart = System.nanoTime()
        sqlite.addAll(docIds, sqliteCopies)
        val sqIngestNs = System.nanoTime() - sqIngestStart
        Log.i(TAG, "sqlite ingest ${cfg.nDocs} × dim=${cfg.dim}: ${sqIngestNs / 1_000_000L} ms")

        // Run SQLite queries + capture ground-truth top-k per query.
        val sqLatUs = LongArray(cfg.nQueries)
        val truthTopK = Array(cfg.nQueries) { Array<String>(cfg.k) { "" } }
        for (qi in 0 until cfg.nQueries) {
            val q = docVecs[qIdxs[qi]].copyOf()
            val t0 = System.nanoTime()
            val res = sqlite.search(q, cfg.k)
            sqLatUs[qi] = (System.nanoTime() - t0) / 1_000L
            for (j in 0 until cfg.k) truthTopK[qi][j] = if (j < res.size) res[j].first else ""
        }
        val sqFileBytes = sqlite.dbFileSizeBytes()
        sqlite.close()

        // ── sqlite-vector-ai (SQLiteAI commercial extension, vector_quantize_scan)
        // The competing commercial product. Statically linked SQLite + the
        // pre-built libvector.so from `ai.sqlite:vector:0.9.80` (Elastic 2.0,
        // bench-only). Quantized snapshot is built via
        // `SELECT vector_quantize('emb','vector','max_memory=50MB');` after
        // ingest — that's SQLiteAI's accelerated-scan path, the fairest
        // apples-to-apples with dazzle-sq8 (both are int8 quantisation under
        // the hood). Without the quantize call the scan returns zero rows,
        // so it's the mandatory production shape per their own API.md.
        val svaiCopies = Array(cfg.nDocs) { docVecs[it].copyOf() }
        val svai = SqliteVectorAiVector(context, cfg.dim)
        svai.create()
        val svaiIngestStart = System.nanoTime()
        svai.addAll(docIds, svaiCopies)
        svai.finalizeIndex()
        val svaiIngestNs = System.nanoTime() - svaiIngestStart
        Log.i(TAG, "sqlite-vector-ai ingest+quantize ${cfg.nDocs} × dim=${cfg.dim}: ${svaiIngestNs / 1_000_000L} ms")

        val svaiLatUs = LongArray(cfg.nQueries)
        var svaiHits = 0; var svaiTotal = 0
        for (qi in 0 until cfg.nQueries) {
            val q = docVecs[qIdxs[qi]].copyOf()
            val t0 = System.nanoTime()
            val res = svai.search(q, cfg.k)
            svaiLatUs[qi] = (System.nanoTime() - t0) / 1_000L
            val set = res.map { it.first }.toHashSet()
            val truth = truthTopK[qi].filter { it.isNotEmpty() }.toHashSet()
            svaiHits += set.intersect(truth).size
            svaiTotal += truth.size
        }
        val svaiRecall = if (svaiTotal > 0) svaiHits.toDouble() / svaiTotal else 0.0
        val svaiFileBytes = svai.dbFileSizeBytes()
        svai.close()
        Log.i(TAG, "sqlite-vector-ai recall@${cfg.k}=${"%.4f".format(svaiRecall)} p50=${latencyStats(svaiLatUs)["p50"]}µs p95=${latencyStats(svaiLatUs)["p95"]}µs")

        // ── sqlite-vec (Alex Garcia's OSS brute-force virtual table) ─────────
        // Same input corpus + queries as above. Recall is exact by construction
        // (sqlite-vec's vec0 is a linear scan in tight C with distance_metric
        // =cosine), so the interesting number here is latency vs stock SQLite
        // and vs HNSW.
        val svCopies = Array(cfg.nDocs) { docVecs[it].copyOf() }
        val sv = SqliteVecVector(context, cfg.dim)
        sv.create()
        val svIngestStart = System.nanoTime()
        sv.addAll(docIds, svCopies)
        val svIngestNs = System.nanoTime() - svIngestStart
        Log.i(TAG, "sqlite-vec ingest ${cfg.nDocs} × dim=${cfg.dim}: ${svIngestNs / 1_000_000L} ms")

        val svLatUs = LongArray(cfg.nQueries)
        var svHits = 0; var svTotal = 0
        for (qi in 0 until cfg.nQueries) {
            val q = docVecs[qIdxs[qi]].copyOf()
            val t0 = System.nanoTime()
            val res = sv.search(q, cfg.k)
            svLatUs[qi] = (System.nanoTime() - t0) / 1_000L
            val set = res.map { it.first }.toHashSet()
            val truth = truthTopK[qi].filter { it.isNotEmpty() }.toHashSet()
            svHits += set.intersect(truth).size
            svTotal += truth.size
        }
        val svRecall = if (svTotal > 0) svHits.toDouble() / svTotal else 0.0
        val svFileBytes = sv.dbFileSizeBytes()
        sv.close()
        Log.i(TAG, "sqlite-vec recall@${cfg.k}=${"%.4f".format(svRecall)} p50=${latencyStats(svLatUs)["p50"]}µs p95=${latencyStats(svLatUs)["p95"]}µs")

        // ── ObjectBox-vector (HNSW in C++ via the ObjectBox library) ─────────
        // ObjectBox 4.x/5.x compiles its HNSW parameters at schema time; the
        // benchmark entity uses dimensions=384 with distanceType=COSINE. Shorter
        // dims are zero-padded (invisible to cosine), so the recall comparison
        // is still apples-to-apples against the sqlite brute-force truth.
        // Configs with dim > 384 skip ObjectBox: bumping the baked dim would
        // invalidate the already-published 384 baseline (HNSW cost grows with
        // dim even after zero-padding), and the realistic sweep reports
        // dazzle/sqlite-vec/sqlite-brute numbers for those rows instead.
        val runObjectBox = cfg.dim <= 384
        var obIngestNs: Long = 0L
        var obLatUs: LongArray = LongArray(0)
        var obRecall: Double = Double.NaN
        var obFileBytes: Long = 0L
        if (runObjectBox) {
            val obCopies = Array(cfg.nDocs) { docVecs[it].copyOf() }
            val ob = ObjectBoxVectorBackend(context, cfg.dim)
            ob.create()
            val obIngestStart = System.nanoTime()
            ob.addAll(docIds, obCopies)
            obIngestNs = System.nanoTime() - obIngestStart
            Log.i(TAG, "objectbox ingest ${cfg.nDocs} × dim=${cfg.dim}: ${obIngestNs / 1_000_000L} ms")

            obLatUs = LongArray(cfg.nQueries)
            var obHits = 0; var obTotal = 0
            for (qi in 0 until cfg.nQueries) {
                val q = docVecs[qIdxs[qi]].copyOf()
                val t0 = System.nanoTime()
                val res = ob.search(q, cfg.k)
                obLatUs[qi] = (System.nanoTime() - t0) / 1_000L
                val set = res.map { it.first }.toHashSet()
                val truth = truthTopK[qi].filter { it.isNotEmpty() }.toHashSet()
                obHits += set.intersect(truth).size
                obTotal += truth.size
            }
            obRecall = if (obTotal > 0) obHits.toDouble() / obTotal else 0.0
            obFileBytes = ob.dbSizeBytes()
            ob.close()
            Log.i(TAG, "objectbox recall@${cfg.k}=${"%.4f".format(obRecall)} p50=${latencyStats(obLatUs)["p50"]}µs p95=${latencyStats(obLatUs)["p95"]}µs")
        } else {
            obIngestNs  = 0L
            obLatUs     = LongArray(0)
            obRecall    = Double.NaN
            obFileBytes = 0L
            Log.i(TAG, "objectbox skipped (dim=${cfg.dim} > entity dim 384)")
        }

        // ── dazzle-vector (HNSW) ─────────────────────────────────────────────
        if (skipDazzle) {
            Log.i(TAG, "dazzle engines skipped (CPU lacks asimdhp/asimddp)")
            val skippedDazzle = mapOf(
                "skipped" to true,
                "reason"  to "CPU lacks asimdhp/asimddp; libvalkeysearch built with -march=armv8.2-a+fp16+dotprod",
            )
            return linkedMapOf(
                "dim" to cfg.dim,
                "n_docs" to cfg.nDocs,
                "n_queries" to cfg.nQueries,
                "k" to cfg.k,
                "sqlite" to mapOf(
                    "ingest_total_ms" to (sqIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (sqIngestNs / 1_000.0 / cfg.nDocs),
                    "search_lat_us"   to latencyStats(sqLatUs),
                    "db_file_bytes"   to sqFileBytes,
                ),
                "sqlite_vec" to mapOf(
                    "ingest_total_ms" to (svIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (svIngestNs / 1_000.0 / cfg.nDocs),
                    "recall_at_k"     to svRecall,
                    "search_lat_us"   to latencyStats(svLatUs),
                    "db_file_bytes"   to svFileBytes,
                ),
                "sqlite_vector_ai" to mapOf(
                    "ingest_total_ms" to (svaiIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (svaiIngestNs / 1_000.0 / cfg.nDocs),
                    "recall_at_k"     to svaiRecall,
                    "search_lat_us"   to latencyStats(svaiLatUs),
                    "db_file_bytes"   to svaiFileBytes,
                ),
                "objectbox" to if (runObjectBox) mapOf(
                    "ingest_total_ms" to (obIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (obIngestNs / 1_000.0 / cfg.nDocs),
                    "recall_at_k"     to obRecall,
                    "search_lat_us"   to latencyStats(obLatUs),
                    "db_file_bytes"   to obFileBytes,
                ) else mapOf(
                    "skipped" to true,
                    "reason"  to "entity compiled with dimensions=384; cfg.dim=${cfg.dim} > 384",
                ),
                "dazzle_hnsw"        to skippedDazzle,
                "dazzle_sq8"         to skippedDazzle,
                "dazzle_sq8_rerank"  to skippedDazzle,
                "dazzle_f16"         to skippedDazzle,
            )
        }

        // Server is started once at run() scope. Each config creates a fresh
        // uniquely-named index; FT.CREATE of a duplicate name replies with
        // "Index already exists" which the SDK wrapper reports as false.
        val client = DazzleServer.client()
        val idx = client.vectorIndex(
            name        = "bench_d${cfg.dim}_n${cfg.nDocs}",
            hashPrefix  = "vb:d${cfg.dim}n${cfg.nDocs}:",
            vectorField = "emb",
            dim         = cfg.dim,
            algorithm   = VectorIndex.Algorithm.HNSW,
            metric      = VectorIndex.Metric.COSINE,
        )
        check(idx.create()) { "FT.CREATE failed" }

        // Re-key ids for the dazzle index so they share the registered prefix.
        val dzIds = Array(cfg.nDocs) { "vb:d${cfg.dim}n${cfg.nDocs}:$it" }

        val dzIngestStart = System.nanoTime()
        idx.addBatchDirect(dzIds, docVecs)
        val dzIngestNs = System.nanoTime() - dzIngestStart
        Log.i(TAG, "dazzle ingest ${cfg.nDocs} × dim=${cfg.dim}: ${dzIngestNs / 1_000_000L} ms")

        // Sweep efRuntime
        val dzByEf = mutableListOf<Map<String, Any?>>()
        for (ef in cfg.efRuntimes) {
            val dzLatUs = LongArray(cfg.nQueries)
            var recallHits = 0
            var totalPairs = 0
            for (qi in 0 until cfg.nQueries) {
                val q = docVecs[qIdxs[qi]]
                val t0 = System.nanoTime()
                val res = idx.searchDirect(q, cfg.k, efRuntime = ef)
                dzLatUs[qi] = (System.nanoTime() - t0) / 1_000L

                // Convert dazzle ids back to the short corpus id for comparison.
                // (dazzle ids include the prefix, sqlite ids are "doc:<i>".)
                val dzSet = res.map { it.first }.toHashSet()
                val truthSet = truthTopK[qi].filter { it.isNotEmpty() }.map { sq ->
                    // sqlite id "doc:N" → dazzle id "vb:d…n…:N"
                    val n = sq.substringAfter("doc:")
                    "vb:d${cfg.dim}n${cfg.nDocs}:$n"
                }.toHashSet()
                recallHits += dzSet.intersect(truthSet).size
                totalPairs += truthSet.size
            }
            val recall = if (totalPairs > 0) recallHits.toDouble() / totalPairs else 0.0
            dzByEf += mapOf(
                "ef_runtime" to ef,
                "recall_at_k" to recall,
                "search_lat_us" to latencyStats(dzLatUs),
            )
            Log.i(TAG, "  ef=$ef recall@${cfg.k}=${"%.4f".format(recall)}  p50=${latencyStats(dzLatUs)["p50"]}µs p95=${latencyStats(dzLatUs)["p95"]}µs")
        }
        // Capture HNSW footprint in isolation, then wipe so the next
        // engine builds its index from a clean keyspace and the
        // measurement is per-engine instead of cumulative.
        val dzBytes = measureDazzleBytes(client)
        runCatching { idx.drop() }
        runCatching { DazzleServer.directCommand("FLUSHALL") }

        // Per-feature quantised-Dazzle skip (CPU lacks asimdhp / asimddp).
        // HNSW (fp32) is already done above and runs on every arm64-v8a
        // chip via simsimd's runtime dispatcher; the three quantised
        // variants below use direct fp16 / SDOT intrinsics that the
        // compiler emits unconditionally and that SIGILL on Cortex-A73.
        if (skipQuantizedDazzle) {
            Log.i(TAG, "dazzle-sq8 / f16 / sq8+rerank skipped (CPU lacks asimdhp/asimddp)")
            val skippedQ = mapOf(
                "skipped" to true,
                "reason"  to "CPU lacks asimdhp/asimddp; quantised Dazzle variants use direct fp16/SDOT intrinsics",
            )
            return linkedMapOf(
                "dim" to cfg.dim,
                "n_docs" to cfg.nDocs,
                "n_queries" to cfg.nQueries,
                "k" to cfg.k,
                "sqlite" to mapOf(
                    "ingest_total_ms" to (sqIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (sqIngestNs / 1_000.0 / cfg.nDocs),
                    "search_lat_us"   to latencyStats(sqLatUs),
                    "db_file_bytes"   to sqFileBytes,
                ),
                "sqlite_vec" to mapOf(
                    "ingest_total_ms" to (svIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (svIngestNs / 1_000.0 / cfg.nDocs),
                    "recall_at_k"     to svRecall,
                    "search_lat_us"   to latencyStats(svLatUs),
                    "db_file_bytes"   to svFileBytes,
                ),
                "sqlite_vector_ai" to mapOf(
                    "ingest_total_ms" to (svaiIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (svaiIngestNs / 1_000.0 / cfg.nDocs),
                    "recall_at_k"     to svaiRecall,
                    "search_lat_us"   to latencyStats(svaiLatUs),
                    "db_file_bytes"   to svaiFileBytes,
                ),
                "objectbox" to if (runObjectBox) mapOf(
                    "ingest_total_ms" to (obIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (obIngestNs / 1_000.0 / cfg.nDocs),
                    "recall_at_k"     to obRecall,
                    "search_lat_us"   to latencyStats(obLatUs),
                    "db_file_bytes"   to obFileBytes,
                ) else mapOf(
                    "skipped" to true,
                    "reason"  to "entity compiled with dimensions=384; cfg.dim=${cfg.dim} > 384",
                ),
                "dazzle_hnsw" to mapOf(
                    "ingest_total_ms" to (dzIngestNs / 1_000_000L),
                    "ingest_avg_us"   to (dzIngestNs / 1_000.0 / cfg.nDocs),
                    "db_file_bytes"   to dzBytes,
                    "by_ef"           to dzByEf,
                ),
                "dazzle_sq8"        to skippedQ,
                "dazzle_sq8_rerank" to skippedQ,
                "dazzle_f16"        to skippedQ,
            )
        }

        // ── dazzle-vector (HNSW_SQ8 — int8 scalar quantisation) ─────────────
        // Same HNSW params (M=32, efC=400) but storage is int8[dim] per point
        // with simsimd_cos_i8 (NEON SDOT) as the distance. ~4× memory win,
        // variable latency/recall delta — that's what this section measures.
        val idxQ = client.vectorIndex(
            name        = "benchq_d${cfg.dim}_n${cfg.nDocs}",
            hashPrefix  = "vbq:d${cfg.dim}n${cfg.nDocs}:",
            vectorField = "emb",
            dim         = cfg.dim,
            algorithm   = VectorIndex.Algorithm.HNSW_SQ8,
            metric      = VectorIndex.Metric.COSINE,
        )
        check(idxQ.create()) { "HNSW_SQ8 create failed" }
        val dzQIds = Array(cfg.nDocs) { "vbq:d${cfg.dim}n${cfg.nDocs}:$it" }

        val dzQIngestStart = System.nanoTime()
        idxQ.addBatchDirect(dzQIds, docVecs)
        val dzQIngestNs = System.nanoTime() - dzQIngestStart
        Log.i(TAG, "dazzle-sq8 ingest ${cfg.nDocs} × dim=${cfg.dim}: ${dzQIngestNs / 1_000_000L} ms")

        val dzQByEf = mutableListOf<Map<String, Any?>>()
        for (ef in cfg.efRuntimes) {
            val lat = LongArray(cfg.nQueries)
            var hits = 0; var totalPairs = 0
            for (qi in 0 until cfg.nQueries) {
                val q = docVecs[qIdxs[qi]]
                val t0 = System.nanoTime()
                val res = idxQ.searchDirect(q, cfg.k, efRuntime = ef)
                lat[qi] = (System.nanoTime() - t0) / 1_000L
                val set = res.map { it.first }.toHashSet()
                val truthSet = truthTopK[qi].filter { it.isNotEmpty() }.map { sq ->
                    val n = sq.substringAfter("doc:")
                    "vbq:d${cfg.dim}n${cfg.nDocs}:$n"
                }.toHashSet()
                hits += set.intersect(truthSet).size
                totalPairs += truthSet.size
            }
            val recall = if (totalPairs > 0) hits.toDouble() / totalPairs else 0.0
            dzQByEf += mapOf(
                "ef_runtime" to ef,
                "recall_at_k" to recall,
                "search_lat_us" to latencyStats(lat),
            )
            Log.i(TAG, "  sq8 ef=$ef recall@${cfg.k}=${"%.4f".format(recall)}  p50=${latencyStats(lat)["p50"]}µs p95=${latencyStats(lat)["p95"]}µs")
        }
        val dzQBytes = measureDazzleBytes(client)
        runCatching { idxQ.drop() }
        runCatching { DazzleServer.directCommand("FLUSHALL") }

        // ── dazzle-vector (HNSW_F16 — half-precision storage) ──────────────
        // 2 B/dim vs 4 B/dim for fp32. simsimd_dot_f16_neon runs natively on
        // armv8.2-a+fp16 (FMLA on fp16 lanes). Recall expected to match fp32
        // within 1-2 points — fp16 has 11 bits of mantissa, plenty for
        // embeddings trained with fp32 loss.
        val idxH = client.vectorIndex(
            name        = "benchh_d${cfg.dim}_n${cfg.nDocs}",
            hashPrefix  = "vbh:d${cfg.dim}n${cfg.nDocs}:",
            vectorField = "emb",
            dim         = cfg.dim,
            algorithm   = VectorIndex.Algorithm.HNSW_F16,
            metric      = VectorIndex.Metric.COSINE,
        )
        check(idxH.create()) { "HNSW_F16 create failed" }
        val dzHIds = Array(cfg.nDocs) { "vbh:d${cfg.dim}n${cfg.nDocs}:$it" }

        val dzHIngestStart = System.nanoTime()
        idxH.addBatchDirect(dzHIds, docVecs)
        val dzHIngestNs = System.nanoTime() - dzHIngestStart
        Log.i(TAG, "dazzle-f16 ingest ${cfg.nDocs} × dim=${cfg.dim}: ${dzHIngestNs / 1_000_000L} ms")

        val dzHByEf = mutableListOf<Map<String, Any?>>()
        for (ef in cfg.efRuntimes) {
            val lat = LongArray(cfg.nQueries)
            var hits = 0; var totalPairs = 0
            for (qi in 0 until cfg.nQueries) {
                val q = docVecs[qIdxs[qi]]
                val t0 = System.nanoTime()
                val res = idxH.searchDirect(q, cfg.k, efRuntime = ef)
                lat[qi] = (System.nanoTime() - t0) / 1_000L
                val set = res.map { it.first }.toHashSet()
                val truthSet = truthTopK[qi].filter { it.isNotEmpty() }.map { sq ->
                    val n = sq.substringAfter("doc:")
                    "vbh:d${cfg.dim}n${cfg.nDocs}:$n"
                }.toHashSet()
                hits += set.intersect(truthSet).size
                totalPairs += truthSet.size
            }
            val recall = if (totalPairs > 0) hits.toDouble() / totalPairs else 0.0
            dzHByEf += mapOf(
                "ef_runtime" to ef,
                "recall_at_k" to recall,
                "search_lat_us" to latencyStats(lat),
            )
            Log.i(TAG, "  f16 ef=$ef recall@${cfg.k}=${"%.4f".format(recall)}  p50=${latencyStats(lat)["p50"]}µs p95=${latencyStats(lat)["p95"]}µs")
        }
        val dzHBytes = measureDazzleBytes(client)
        runCatching { idxH.drop() }
        runCatching { DazzleServer.directCommand("FLUSHALL") }

        // ── dazzle-vector (HNSW_SQ8 + fp32 rerank) ─────────────────────────
        // Same int8 HNSW traversal, but top-k·α candidates get rescored with
        // simsimd_dot_f32 against a parallel fp32 side-store. Aims to recover
        // recall to ~1.00 while keeping most of the SQ8 latency win.
        val idxR = client.vectorIndex(
            name        = "benchr_d${cfg.dim}_n${cfg.nDocs}",
            hashPrefix  = "vbr:d${cfg.dim}n${cfg.nDocs}:",
            vectorField = "emb",
            dim         = cfg.dim,
            algorithm   = VectorIndex.Algorithm.HNSW_SQ8_RERANK,
            metric      = VectorIndex.Metric.COSINE,
        )
        check(idxR.create()) { "HNSW_SQ8_RERANK create failed" }
        val dzRIds = Array(cfg.nDocs) { "vbr:d${cfg.dim}n${cfg.nDocs}:$it" }

        val dzRIngestStart = System.nanoTime()
        idxR.addBatchDirect(dzRIds, docVecs)
        val dzRIngestNs = System.nanoTime() - dzRIngestStart
        Log.i(TAG, "dazzle-sq8-rerank ingest ${cfg.nDocs} × dim=${cfg.dim}: ${dzRIngestNs / 1_000_000L} ms")

        val dzRByEf = mutableListOf<Map<String, Any?>>()
        for (ef in cfg.efRuntimes) {
            val lat = LongArray(cfg.nQueries)
            var hits = 0; var totalPairs = 0
            for (qi in 0 until cfg.nQueries) {
                val q = docVecs[qIdxs[qi]]
                val t0 = System.nanoTime()
                val res = idxR.searchDirect(q, cfg.k, efRuntime = ef)
                lat[qi] = (System.nanoTime() - t0) / 1_000L
                val set = res.map { it.first }.toHashSet()
                val truthSet = truthTopK[qi].filter { it.isNotEmpty() }.map { sq ->
                    val n = sq.substringAfter("doc:")
                    "vbr:d${cfg.dim}n${cfg.nDocs}:$n"
                }.toHashSet()
                hits += set.intersect(truthSet).size
                totalPairs += truthSet.size
            }
            val recall = if (totalPairs > 0) hits.toDouble() / totalPairs else 0.0
            dzRByEf += mapOf(
                "ef_runtime" to ef,
                "recall_at_k" to recall,
                "search_lat_us" to latencyStats(lat),
            )
            Log.i(TAG, "  sq8+rerank ef=$ef recall@${cfg.k}=${"%.4f".format(recall)}  p50=${latencyStats(lat)["p50"]}µs p95=${latencyStats(lat)["p95"]}µs")
        }
        val dzRBytes = measureDazzleBytes(client)
        runCatching { idxR.drop() }
        runCatching { DazzleServer.directCommand("FLUSHALL") }

        return linkedMapOf(
            "dim" to cfg.dim,
            "n_docs" to cfg.nDocs,
            "n_queries" to cfg.nQueries,
            "k" to cfg.k,
            "sqlite" to mapOf(
                "ingest_total_ms" to (sqIngestNs / 1_000_000L),
                "ingest_avg_us"   to (sqIngestNs / 1_000.0 / cfg.nDocs),
                "search_lat_us"   to latencyStats(sqLatUs),
                "db_file_bytes"   to sqFileBytes,
            ),
            "sqlite_vec" to mapOf(
                "ingest_total_ms" to (svIngestNs / 1_000_000L),
                "ingest_avg_us"   to (svIngestNs / 1_000.0 / cfg.nDocs),
                "recall_at_k"     to svRecall,
                "search_lat_us"   to latencyStats(svLatUs),
                "db_file_bytes"   to svFileBytes,
            ),
            "sqlite_vector_ai" to mapOf(
                // Includes the mandatory `vector_quantize` call in the ingest
                // time, so the total is ingest + quantize. That matches what
                // any production user would actually do before a first query.
                "ingest_total_ms" to (svaiIngestNs / 1_000_000L),
                "ingest_avg_us"   to (svaiIngestNs / 1_000.0 / cfg.nDocs),
                "recall_at_k"     to svaiRecall,
                "search_lat_us"   to latencyStats(svaiLatUs),
                "db_file_bytes"   to svaiFileBytes,
            ),
            "objectbox" to if (runObjectBox) mapOf(
                "ingest_total_ms" to (obIngestNs / 1_000_000L),
                "ingest_avg_us"   to (obIngestNs / 1_000.0 / cfg.nDocs),
                "recall_at_k"     to obRecall,
                "search_lat_us"   to latencyStats(obLatUs),
                "db_file_bytes"   to obFileBytes,
            ) else mapOf(
                "skipped" to true,
                "reason"  to "entity compiled with dimensions=384; cfg.dim=${cfg.dim} > 384",
            ),
            "dazzle_hnsw" to mapOf(
                "ingest_total_ms" to (dzIngestNs / 1_000_000L),
                "ingest_avg_us"   to (dzIngestNs / 1_000.0 / cfg.nDocs),
                // Reported in bytes from `INFO memory` →
                // `used_memory_dataset` after the engine's queries finish
                // and BEFORE the FLUSHALL that resets state for the next
                // engine. Equivalent semantic to the `db_file_bytes` of
                // the SQLite/sqlite-vec/SQLiteAI rows: storage occupied
                // by the engine after the workload.
                "db_file_bytes"   to dzBytes,
                "by_ef"           to dzByEf,
            ),
            "dazzle_sq8" to mapOf(
                "ingest_total_ms" to (dzQIngestNs / 1_000_000L),
                "ingest_avg_us"   to (dzQIngestNs / 1_000.0 / cfg.nDocs),
                "db_file_bytes"   to dzQBytes,
                "by_ef"           to dzQByEf,
            ),
            "dazzle_sq8_rerank" to mapOf(
                "ingest_total_ms" to (dzRIngestNs / 1_000_000L),
                "ingest_avg_us"   to (dzRIngestNs / 1_000.0 / cfg.nDocs),
                "db_file_bytes"   to dzRBytes,
                "by_ef"           to dzRByEf,
            ),
            "dazzle_f16" to mapOf(
                "ingest_total_ms" to (dzHIngestNs / 1_000_000L),
                "ingest_avg_us"   to (dzHIngestNs / 1_000.0 / cfg.nDocs),
                "db_file_bytes"   to dzHBytes,
                "by_ef"           to dzHByEf,
            ),
        )
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /**
     * Reads the `used_memory_dataset` value from `INFO memory`. This is the
     * Valkey-internal dataset footprint in bytes (raw values + index
     * overhead, excluding the server's own structures). It's the closest
     * apples-to-apples comparison against the SQLite/sqlite-vec/SQLiteAI
     * `db_file_bytes` numbers in Table 11 — the intent of the column is
     * "how much storage does this engine occupy after ingest", and that's
     * what `used_memory_dataset` measures for an in-memory engine.
     *
     * Returns -1 if the INFO output couldn't be parsed.
     */
    private fun measureDazzleBytes(client: dev.dazzle.sdk.Dazzle): Long {
        // INFO memory lives on the server-singleton, not on the typed
        // client (Dazzle exposes only the typed primitives to keep its
        // public API tight). The `client` parameter is preserved on the
        // helper signature so callers don't have to reach back into
        // DazzleServer themselves at every call site.
        val info = DazzleServer.directCommand("INFO", "memory") ?: return -1L
        for (rawLine in info.split("\n", "\r")) {
            val line = rawLine.trim()
            if (line.startsWith("used_memory_dataset:")) {
                return line.substringAfter(":").trim().toLongOrNull() ?: -1L
            }
        }
        return -1L
    }

    /** Per-CPU ARM extension probe via /proc/cpuinfo. The two flags we
     *  care about for Dazzle's quantised vector kernels:
     *    `asimdhp`  — ARMv8.2 fp16 SIMD (HNSW_F16, HNSW_SQ8+rerank fp32 side)
     *    `asimddp`  — ARMv8.2 dot-product (HNSW_SQ8 SDOT)
     *  Java's `Build.SUPPORTED_ABIS` only reports arm64-v8a in general;
     *  the per-CPU extension bits are not exposed at the JDK level.  */
    data class CpuFeatures(val asimdhp: Boolean, val asimddp: Boolean)

    private fun probeCpuFeatures(): CpuFeatures = try {
        val features = java.io.File("/proc/cpuinfo").readLines()
            .firstOrNull { it.startsWith("Features") }
            ?.substringAfter(":") ?: ""
        val hasFp16    = " asimdhp " in " $features "
        val hasDotProd = " asimddp " in " $features "
        Log.i(TAG, "CPU features: asimdhp=$hasFp16 asimddp=$hasDotProd")
        CpuFeatures(asimdhp = hasFp16, asimddp = hasDotProd)
    } catch (e: Exception) {
        Log.w(TAG, "CPU feature probe failed (${e.message}) — assuming neither feature is available")
        CpuFeatures(asimdhp = false, asimddp = false)
    }

    private fun latencyStats(vs: LongArray): Map<String, Any?> {
        if (vs.isEmpty()) return emptyMap()
        val sorted = vs.copyOf().also { it.sort() }
        fun pct(p: Double): Long = sorted[minOf((sorted.size * p).toInt(), sorted.size - 1)]
        // Persist the raw per-query latency array so the offline
        // bootstrap (research/scripts/bootstrap_vecbench_lats.py) can
        // compute non-parametric CIs on whatever statistic the paper
        // cites — p50, mean, or any quantile — without re-running the
        // bench. The arrival-order array is not sorted on disk so the
        // bootstrap can also study auto-correlation if needed.
        return linkedMapOf(
            "n"            to sorted.size,
            "avg"          to sorted.sum().toDouble() / sorted.size,
            "p50"          to pct(0.50),
            "p95"          to pct(0.95),
            "p99"          to pct(0.99),
            "min"          to sorted.first(),
            "max"          to sorted.last(),
            "latencies_us" to vs.toList(),
        )
    }

    private fun collectDeviceInfo(): Map<String, Any?> = linkedMapOf(
        "model" to Build.MODEL,
        "manufacturer" to Build.MANUFACTURER,
        "board" to Build.BOARD,
        "hardware" to Build.HARDWARE,
        "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
        "android_version" to Build.VERSION.RELEASE,
        "sdk_int" to Build.VERSION.SDK_INT,
        "cpu_cores" to Runtime.getRuntime().availableProcessors(),
    )
}
