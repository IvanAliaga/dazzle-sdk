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

package dev.dazzle.experiment

import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import com.google.gson.GsonBuilder
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.WipeTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random

/**
 * AblationSweep — runs the ablation matrix (K × mode × backend) in a single
 * process and emits one consolidated JSON so the paper can render the
 * "contribution of each optimization layer" figure without stitching
 * dozens of per-cell files.
 *
 * Why a dedicated runner?
 *   MultiAgentTest.run sets env vars *before* DazzleServer.start() and never
 *   stops the server. For a sweep we must flip DAZZLE_PARALLEL_READS between
 *   cells, which requires stop + re-start with a fresh argv. The sweep
 *   groups cells by mode so we pay exactly one stop+start per mode switch.
 *
 * Intent launch:
 *   adb shell am start -n dev.dazzle.experiment.multiagent/dev.dazzle.experiment.MultiAgentActivity \
 *       --es mode sweep \
 *       --es sweep_ks         "1,2,4,8,16" \
 *       --es sweep_backends   "dazzle-precompute,dazzle-incremental" \
 *       --es sweep_modes      "main_thread,parallel" \
 *       --ei sweep_duration_sec 20
 *
 * The matrix is the cartesian product of the three lists. A 5×2×2 sweep
 * (shown above) runs 20 cells; at 20 s/cell + ~0.5 s re-warm, that is
 * ~7 min on Moto g35.
 */
object AblationSweep {

    private const val TAG = "AblationSweep"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    /**
     * One row in the paper's "contribution of each optimization layer"
     * figure.  Each variant triggers a server restart with the given env
     * flag combo — the C layer re-reads them in dwp_init /
     * dazzle_direct_init on every fresh start.
     *
     * The default list below is the layered ablation stack:
     *   baseline:       pipe only, no workers, no snapshot
     *   + workers:      worker pool on, still no snapshot
     *   + snap-linear:  snapshot on, single bucket (pre-hash-index)
     *   + hash-index:   snapshot on, full 16-bucket dispatch
     *
     * Post-EVAL auto-mirror (plan 10) is always on — it is a compile-time
     * feature without an env knob, and the incremental backend cannot be
     * meaningfully benchmarked without it (pure-pipe incremental reads
     * already baseline at ~200 µs each).
     */
    data class Variant(
        val name: String,
        val disableSnapshot: Boolean,
        val singleBucket: Boolean,          // DAZZLE_SNAPSHOT_BUCKETS=1
        val parallel: Boolean,              // DAZZLE_PARALLEL_READS=1
    )

    /** Full 2×2 factorial over {snapshot on/off} × {parallel on/off}, plus
     *  the two bucket modes when snapshot is on. Six cells total (the two
     *  DISABLE_SNAPSHOT=1 rows collapse across BUCKETS). Lets the paper
     *  isolate each layer's independent contribution, not just the
     *  additive ladder. */
    val defaultVariants = listOf(
        Variant("baseline",          disableSnapshot = true,  singleBucket = false, parallel = false),
        Variant("workers",           disableSnapshot = true,  singleBucket = false, parallel = true),
        Variant("snap-linear-serial",disableSnapshot = false, singleBucket = true,  parallel = false),
        Variant("snap-linear",       disableSnapshot = false, singleBucket = true,  parallel = true),
        Variant("hash-index-serial", disableSnapshot = false, singleBucket = false, parallel = false),
        Variant("hash-index",        disableSnapshot = false, singleBucket = false, parallel = true),
    )

    data class Options(
        val variants: List<Variant> = listOf(),      // empty → use defaultVariants
        val ks: List<Int>           = listOf(1, 2, 4, 8),
        val backends: List<String>  = listOf("dazzle-precompute", "dazzle-incremental"),
        val modes: List<MultiAgentTest.Mode> = listOf(),  // legacy; empty now means "use variants"
        val durationSec: Int        = 20,
        val readPct: Int            = 80,
        val workerThreads: Int      = 0,
        val warmupReps: Int         = 20,
    )

    data class Cell(
        val variant: String,
        val k: Int,
        val backend: String,
        val opsPerSec: Double,
        val reads: Long,
        val writes: Long,
        val avgUs: Double,
        val p50Us: Double,
        val p95Us: Double,
        val p99Us: Double,
        val durationSec: Int,
    )

    fun interface Progress { fun emit(line: String) }

    /**
     * Runs the (K × backend) matrix for EXACTLY ONE variant.  The caller
     * (shell driver) is responsible for:
     *
     *   1. am force-stop the host process so state from a prior variant
     *      does not leak.
     *   2. Launch the activity with the variant's env flags as intent
     *      extras (parseSweepOptions builds the Options with a single-
     *      element variants list).
     *   3. Wait for the completion marker, pull the JSON, repeat for the
     *      next variant.
     *
     * Why not loop variants in-process: an embedded Valkey's second
     * valkey_main() invocation in the same process is not robust — the
     * second `start` reliably hangs after the first `stop`. Externalising
     * the variant loop matches the pattern used by run_all_backends.sh
     * and sidesteps the issue.
     */
    suspend fun run(context: Context, opts: Options, onProgress: Progress = Progress {}) {
        fun say(msg: String) { Log.i(TAG, msg); onProgress.emit(msg) }

        val variants = opts.variants.ifEmpty { defaultVariants.take(1) }
        if (variants.size > 1) {
            say("WARNING: multiple variants requested but in-process variant " +
                "switching is unreliable. Running only the first variant " +
                "('${variants[0].name}'). Drive the variant loop from the shell.")
        }
        val variant = variants[0]

        say("═══ AblationSweep ═══")
        say("variant: ${variant.name}")
        say("K=${opts.ks} backends=${opts.backends} dur=${opts.durationSec}s")
        say("cells = ${opts.ks.size * opts.backends.size}")

        // Promote variant flags into the C layer's env space BEFORE starting
        // the server. All three are re-read on every fresh server start by
        // dwp_init (parallel reads) and dazzle_direct_init (snapshot config).
        DazzleServer.nativeSetEnv("DAZZLE_PARALLEL_READS",
            if (variant.parallel) "1" else "0")
        DazzleServer.nativeSetEnv("DAZZLE_DISABLE_SNAPSHOT",
            if (variant.disableSnapshot) "1" else "0")
        DazzleServer.nativeSetEnv("DAZZLE_SNAPSHOT_BUCKETS",
            if (variant.singleBucket) "1" else "16")
        if (opts.workerThreads > 0) {
            DazzleServer.nativeSetEnv(
                "DAZZLE_WORKER_THREADS", opts.workerThreads.toString())
        }

        if (!DazzleServer.isRunning()) {
            say("starting server … DISABLE_SNAP=${variant.disableSnapshot} " +
                "BUCKETS=${if (variant.singleBucket) 1 else 16} " +
                "PARALLEL=${variant.parallel}")
            DazzleServer.start(context, DazzleConfig(
                port        = 6380,
                persistence = DazzlePersistence.None,
                wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            ))
            delay(800)
        } else {
            say("server already running (reusing — caller must force-stop for fresh env)")
        }

        val dataset = DatasetLoader.load(context)
        val results = mutableListOf<Cell>()
        val startedAt = System.currentTimeMillis()

        for (backendName in opts.backends) {
            val backend = createBackend(context, backendName)

            // Pre-populate ONCE per backend: each K in the inner loop
            // re-uses the same loaded dataset, which is exactly the
            // steady-state we care about for the paper.
            backend.flush()
            dataset.readings.forEach { backend.ingest(it) }
            repeat(opts.warmupReps) {
                backend.buildContextBlock(dataset.readings[100].minute)
            }

            for (k in opts.ks) {
                say("  [${variant.name} / $backendName / K=$k]")
                val cell = runCell(backend, backendName, variant.name, k, opts)
                results.add(cell)
                say("    → ${"%.0f".format(cell.opsPerSec)} ops/s  " +
                    "p50=${"%.0f".format(cell.p50Us)} µs  " +
                    "p99=${"%.0f".format(cell.p99Us)} µs")
            }
        }

        val path = saveJson(context, opts, listOf(variant), results, startedAt)
        say("═══ DONE: ${results.size} cells → $path ═══")
    }

    private suspend fun runCell(
        backend: StorageBackend,
        backendName: String,
        variantName: String,
        k: Int,
        opts: Options,
    ): Cell {
        val totalReads  = AtomicLong(0)
        val totalWrites = AtomicLong(0)
        val perAgent = Array(k) { LongArray(0) }

        val startNanos = System.nanoTime()
        val endNanos   = startNanos + opts.durationSec.toLong() * 1_000_000_000L

        coroutineScope {
            val jobs = (0 until k).map { agentId ->
                async(Dispatchers.IO) {
                    val local = ArrayList<Long>(opts.durationSec * 500)
                    val rng = Random(agentId.toLong() * 1_000_003L)
                    while (System.nanoTime() < endNanos) {
                        val isRead = rng.nextInt(100) < opts.readPct
                        val t0 = System.nanoTime()
                        if (isRead) {
                            val minute = 20 + rng.nextInt(180)
                            backend.buildContextBlock(minute)
                            totalReads.incrementAndGet()
                        } else {
                            val minute = 200 + rng.nextInt(100_000)
                            backend.ingest(SensorReading(
                                minute    = minute,
                                timestamp = "synthetic",
                                tempC     = 18.0 + rng.nextDouble() * 15.0,
                                humidity  = 40.0 + rng.nextDouble() * 40.0,
                                anomalous = rng.nextInt(100) < 5,
                            ))
                            totalWrites.incrementAndGet()
                        }
                        local.add(System.nanoTime() - t0)
                    }
                    perAgent[agentId] = local.toLongArray()
                }
            }
            jobs.awaitAll()
        }

        val totalSize = perAgent.sumOf { it.size }
        val all = LongArray(totalSize).also { out ->
            var off = 0
            for (arr in perAgent) { arr.copyInto(out, off); off += arr.size }
        }
        all.sort()

        fun pctile(q: Double): Long =
            if (all.isEmpty()) 0L else all[minOf((all.size * q).toInt(), all.size - 1)]

        val total = totalReads.get() + totalWrites.get()
        return Cell(
            variant      = variantName,
            k            = k,
            backend      = backendName,
            opsPerSec    = total.toDouble() / opts.durationSec.toDouble(),
            reads        = totalReads.get(),
            writes       = totalWrites.get(),
            avgUs        = if (all.isEmpty()) 0.0 else all.average() / 1000.0,
            p50Us        = pctile(0.50) / 1000.0,
            p95Us        = pctile(0.95) / 1000.0,
            p99Us        = pctile(0.99) / 1000.0,
            durationSec  = opts.durationSec,
        )
    }

    private fun createBackend(context: Context, name: String): StorageBackend =
        when (name.lowercase()) {
            "dazzle"             -> DazzleContextManager()
            "dazzle-lua"         -> DazzleLuaContextManager()
            "dazzle-pipeline"    -> DazzlePipelineContextManager()
            "dazzle-hfe"         -> DazzleHFEContextManager()
            "dazzle-hll"         -> DazzleHLLContextManager()
            "dazzle-precompute"  -> DazzlePrecomputeIoTManager()
            "dazzle-incremental" -> DazzleIncrementalIoTManager()
            "valkey"             -> ValkeyContextManager()
            "sqlite"             -> SqliteContextManager(context)
            "objectbox"          -> ObjectBoxContextManager(context)
            "lmdb"               -> LmdbContextManager(context)
            "rocksdb"            -> RocksDbContextManager(context)
            "inmemory"           -> InMemoryContextManager()
            else -> throw IllegalArgumentException("Unknown backend '$name'")
        }

    private fun saveJson(
        context: Context,
        opts: Options,
        variants: List<Variant>,
        cells: List<Cell>,
        startedAt: Long,
    ): String {
        val payload = linkedMapOf<String, Any>(
            "type"          to "ablation_sweep",
            "plan"          to "plan11",
            "timestamp"     to java.time.Instant.now().toString(),
            "started_at_ms" to startedAt,
            "device"        to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            "device_info"   to collectDeviceInfo(context),
            "opts"          to linkedMapOf(
                "ks"            to opts.ks,
                "backends"      to opts.backends,
                "duration_sec"  to opts.durationSec,
                "read_pct"      to opts.readPct,
                "worker_threads" to opts.workerThreads,
            ),
            "variants" to variants.map { v ->
                linkedMapOf(
                    "name"             to v.name,
                    "disable_snapshot" to v.disableSnapshot,
                    "single_bucket"    to v.singleBucket,
                    "parallel"         to v.parallel,
                )
            },
            "cells" to cells.map { c ->
                linkedMapOf(
                    "variant"       to c.variant,
                    "k"             to c.k,
                    "backend"       to c.backend,
                    "ops_per_sec"   to c.opsPerSec,
                    "reads"         to c.reads,
                    "writes"        to c.writes,
                    "duration_sec"  to c.durationSec,
                    "latency_us"    to linkedMapOf(
                        "avg" to c.avgUs,
                        "p50" to c.p50Us,
                        "p95" to c.p95Us,
                        "p99" to c.p99Us,
                    ),
                )
            },
        )

        val ts = System.currentTimeMillis()
        val fileName = "ablation_sweep_$ts.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fileName)
        } catch (_: Exception) {
            File(context.filesDir, fileName)
        }
        file.writeText(gson.toJson(payload))
        Log.i(TAG, "Sweep results saved: ${file.absolutePath}")
        return file.absolutePath
    }

    private fun collectDeviceInfo(context: Context): Map<String, Any?> {
        val memTotalKb = runCatching {
            File("/proc/meminfo").readLines()
                .firstOrNull { it.startsWith("MemTotal") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()
        }.getOrNull()
        return linkedMapOf(
            "model"           to Build.MODEL,
            "manufacturer"    to Build.MANUFACTURER,
            "board"           to Build.BOARD,
            "cpu_cores"       to Runtime.getRuntime().availableProcessors(),
            "ram_total_kb"    to memTotalKb,
            "android_version" to Build.VERSION.RELEASE,
            "sdk_int"         to Build.VERSION.SDK_INT,
            "abi"             to Build.SUPPORTED_ABIS.firstOrNull(),
        )
    }
}
