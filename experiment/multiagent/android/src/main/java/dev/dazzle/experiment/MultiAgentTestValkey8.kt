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
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random

/**
 * MultiAgentTest — measures Plan 02 parallel-read dispatch under concurrent load.
 *
 * Single-client benchmarks (StorageOnlyTest, LLM ExperimentPipelineIoTValkey8) can NOT
 * validate Plan 02: with one caller there is no concurrency to spread across
 * the worker pool. This harness spins up K coroutines hammering Dazzle with
 * an 80/20 read/write mix for T seconds and reports aggregate throughput plus
 * per-agent p50/p95 latency.
 *
 * The DAZZLE_PARALLEL_READS env var is set *before* DazzleServer.start() via
 * the JNI bridge nativeSetEnv — that is the only mode-switch needed. Default
 * mode = "0" (MainThread). Flip to "1" to exercise the worker pool.
 *
 * Launch example:
 *   adb shell am start -n dev.dazzle.experiment.multiagent/dev.dazzle.experiment.MultiAgentActivity \
 *       --es mode parallel --ei agents 8 --ei duration_sec 30
 */
object MultiAgentTestValkey8 {

    private const val TAG = "MultiAgentTest"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    enum class Mode(val envFlag: String) {
        MAIN_THREAD("0"),
        PARALLEL_READS("1"),
    }

    data class Options(
        val mode: Mode = Mode.MAIN_THREAD,
        val backend: String = "dazzle",
        val agents: Int = 8,
        val durationSec: Int = 30,
        val readPct: Int = 80,
        val windowMinutes: Int = 20,
        val clusterEnabled: Boolean = false,
        val workerThreads: Int = 0,   // 0 → leave default (min(4, cores-1))
    )

    /**
     * Progress callback. Called from an arbitrary thread — the Activity should
     * marshal updates to the UI thread.
     */
    fun interface Progress { fun emit(line: String) }

    suspend fun run(context: Context, opts: Options, onProgress: Progress = Progress {}) {
        fun say(msg: String) {
            Log.i(TAG, msg)
            onProgress.emit(msg)
        }

        say("═══ MultiAgentTest ═══")
        say("mode=${opts.mode} agents=${opts.agents} dur=${opts.durationSec}s " +
            "read=${opts.readPct}% cluster=${opts.clusterEnabled}")

        // ── Flip mode flag BEFORE server start ──────────────────────────────
        DazzleServer.nativeSetEnv("DAZZLE_PARALLEL_READS", opts.mode.envFlag)
        say("DAZZLE_PARALLEL_READS=${opts.mode.envFlag}")

        // Worker-count knob.  Plan 02 default (min(4, cores-1)) is tuned
        // for high-core-count SoCs; the Moto g35 (8-core, thermally
        // throttled) benches best with a smaller pool since agent threads
        // compete with workers for cores.  Honours an intent-provided
        // override (Options.workerThreads) so bench automation can sweep.
        if (opts.workerThreads > 0) {
            DazzleServer.nativeSetEnv(
                "DAZZLE_WORKER_THREADS", opts.workerThreads.toString())
            say("DAZZLE_WORKER_THREADS=${opts.workerThreads}")
        }

        if (opts.clusterEnabled) {
            DazzleServer.nativeSetEnv("DAZZLE_CLUSTER_ENABLED", "1")
            say("DAZZLE_CLUSTER_ENABLED=1")
        }

        if (!DazzleServer.isRunning()) {
            say("Starting embedded Dazzle server…")
            DazzleServer.start(context, DazzleConfig(
                port = 6380,
                persistence = DazzlePersistence.None,
                wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            ))
            Thread.sleep(800)
            say("Server ready ✓")
        } else {
            say("Server already running (reusing)")
        }

        // ── Pre-populate dataset ────────────────────────────────────────────
        val backend: StorageBackend = createBackend(context, opts.backend)
        say("backend: ${backend.backendName} (${opts.backend})")
        backend.flush()
        say("flushed")

        // Snapshot battery BEFORE the concurrent phase so the JSON matches the
        // LLM experiment schema and downstream scripts can diff battery drain.
        val batteryBefore = snapshotBattery(context)
        val dataset = DatasetLoader.load(context)
        dataset.readings.forEachIndexed { i, r ->
            backend.ingest(r)
            if (i > 0 && i % 50 == 0) say("  ingested $i/${dataset.readings.size}…")
        }
        say("ingested ${dataset.readings.size} readings")

        // Warm up
        repeat(20) { backend.buildContextBlock(dataset.readings[100].minute, opts.windowMinutes) }
        say("warm-up ✓ — launching ${opts.agents} agents for ${opts.durationSec}s")

        // ── Fan out K coroutines ────────────────────────────────────────────
        val totalReads  = AtomicLong(0)
        val totalWrites = AtomicLong(0)
        val perAgentSamples = Array(opts.agents) { LongArray(0) }

        val startNanos = System.nanoTime()
        val endNanos   = startNanos + opts.durationSec.toLong() * 1_000_000_000L

        // coroutineScope inherits the caller's context (no runBlocking needed since run() is
        // suspend). Agent tasks are dispatched on Dispatchers.IO so each blocking JNI call
        // gets its own thread from the unbounded IO pool — no thread exhaustion under K=8.
        coroutineScope {
            // Progress ticker — light coroutine, no blocking calls
            val ticker = launch {
                var lastOps = 0L
                while (System.nanoTime() < endNanos) {
                    delay(1000)
                    val cur = totalReads.get() + totalWrites.get()
                    val instRate = cur - lastOps
                    lastOps = cur
                    val elapsed = (System.nanoTime() - startNanos) / 1_000_000_000.0
                    say("  t=${"%.0f".format(elapsed)}s  ops=$cur  (+$instRate ops/s)")
                }
            }

            val jobs = (0 until opts.agents).map { agentId ->
                async(Dispatchers.IO) {
                    val local = ArrayList<Long>(opts.durationSec * 500)
                    val rng   = Random(agentId.toLong() * 1_000_003L)
                    while (System.nanoTime() < endNanos) {
                        val isRead = rng.nextInt(100) < opts.readPct
                        val t0 = System.nanoTime()
                        if (isRead) {
                            val minute = 20 + rng.nextInt(180)
                            backend.buildContextBlock(minute, opts.windowMinutes)
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
                    perAgentSamples[agentId] = local.toLongArray()
                }
            }
            jobs.awaitAll()
            ticker.cancel()
        }

        // ── Aggregate ───────────────────────────────────────────────────────
        // Use LongArray end-to-end to avoid boxing 100k+ longs into Long
        // objects — that boxing pegged a Moto g35 for minutes with the naive
        // flatMap + toList + sorted() pipeline.
        val totalSize = perAgentSamples.sumOf { it.size }
        val allSamples = LongArray(totalSize).also { out ->
            var off = 0
            for (arr in perAgentSamples) {
                arr.copyInto(out, off)
                off += arr.size
            }
        }
        allSamples.sort()

        val total = totalReads.get() + totalWrites.get()
        val opsPerSec = total.toDouble() / opts.durationSec.toDouble()

        fun pctile(sorted: LongArray, q: Double): Long =
            if (sorted.isEmpty()) 0L
            else sorted[minOf((sorted.size * q).toInt(), sorted.size - 1)]

        val p50 = pctile(allSamples, 0.50)
        val p95 = pctile(allSamples, 0.95)
        val p99 = pctile(allSamples, 0.99)
        val avg = if (allSamples.isEmpty()) 0.0 else allSamples.average()

        val perAgentStats = perAgentSamples.mapIndexed { idx, arr ->
            val sorted = arr.copyOf().also { it.sort() }
            mapOf(
                "agent"  to idx,
                "ops"    to arr.size,
                "p50_us" to (pctile(sorted, 0.50) / 1000.0),
                "p95_us" to (pctile(sorted, 0.95) / 1000.0),
                "p99_us" to (pctile(sorted, 0.99) / 1000.0),
                "avg_us" to (if (sorted.isEmpty()) 0.0 else sorted.average() / 1000.0),
            )
        }

        val batteryAfter = snapshotBattery(context)

        say("═══ RESULT ═══")
        say("  total=$total reads=${totalReads.get()} writes=${totalWrites.get()}")
        say("  throughput=${"%.1f".format(opsPerSec)} ops/s aggregate")
        say("  latency: avg=${"%.1f".format(avg / 1000.0)} µs  p50=${"%.1f".format(p50 / 1000.0)} µs  " +
            "p95=${"%.1f".format(p95 / 1000.0)} µs  p99=${"%.1f".format(p99 / 1000.0)} µs")

        val result = linkedMapOf<String, Any>(
            "type"              to "multiagent_bench",
            "plan"              to "plan02",
            "mode"              to opts.mode.name.lowercase(),
            "backend"           to opts.backend,
            "backend_key"       to opts.backend.lowercase(),
            "cluster_enabled"   to opts.clusterEnabled,
            "agents"            to opts.agents,
            "duration_sec"      to opts.durationSec,
            "read_pct"          to opts.readPct,
            "platform"          to "Android",
            "timestamp"         to java.time.Instant.now().toString(),
            "device"            to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            "device_info"       to collectDeviceInfo(context),
            "battery_before"    to batteryBefore,
            "battery_after"     to batteryAfter,
            "total_ops"         to total,
            "reads"             to totalReads.get(),
            "writes"            to totalWrites.get(),
            "aggregate_ops_per_sec" to opsPerSec,
            "latency_us"        to mapOf(
                "avg" to (avg / 1000.0),
                "p50" to (p50 / 1000.0),
                "p95" to (p95 / 1000.0),
                "p99" to (p99 / 1000.0),
            ),
            "per_agent"         to perAgentStats,
        )

        val path = saveJson(context, result, opts)
        say("saved: $path")
    }

    private fun saveJson(context: Context, result: Map<String, Any>, opts: Options): String {
        val ts = System.currentTimeMillis()
        val suffix = "${opts.mode.name.lowercase()}" +
            (if (opts.clusterEnabled) "_cluster" else "") +
            "_k${opts.agents}_${opts.durationSec}s"
        val fileName = "multiagent_${suffix}_$ts.json"
        val json = gson.toJson(result)
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fileName)
        } catch (_: Exception) {
            File(context.filesDir, fileName)
        }
        file.writeText(json)
        Log.i(TAG, "Saved: ${file.absolutePath}")
        return file.absolutePath
    }

    /**
     * Backend factory — mirrors experiment/backends/android/core/StorageOnlyTest.kt
     * so MultiAgentTest can exercise any Dazzle variant (or sqlite/lmdb/etc)
     * for apples-to-apples comparison with the LLM + storage-only experiments.
     */
    private fun createBackend(context: Context, name: String): StorageBackend =
        when (name.lowercase()) {
            "dazzle"            -> DazzleContextManager()
            "dazzle-lua"        -> DazzleLuaContextManager()
            "dazzle-pipeline"   -> DazzlePipelineContextManager()
            "dazzle-hfe"        -> DazzleHFEContextManager()
            "dazzle-hll"        -> DazzleHLLContextManager()
            "dazzle-precompute"   -> DazzlePrecomputeIoTManager()
            "dazzle-incremental" -> DazzleIncrementalIoTManager()
            "valkey"            -> ValkeyContextManager()
            "sqlite"            -> SqliteContextManager(context)
            "objectbox"         -> ObjectBoxContextManager(context)
            "lmdb"              -> LmdbContextManager(context)
            "rocksdb"           -> RocksDbContextManager(context)
            "inmemory"          -> InMemoryContextManager()
            else -> throw IllegalArgumentException("Unknown backend '$name'")
        }

    private fun snapshotBattery(context: Context): Map<String, Any?> {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level  = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale  = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val pct    = if (level >= 0 && scale > 0) level.toDouble() / scale.toDouble() else -1.0
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val state  = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING     -> "charging"
            BatteryManager.BATTERY_STATUS_DISCHARGING  -> "unplugged"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "unplugged"
            BatteryManager.BATTERY_STATUS_FULL         -> "full"
            else                                       -> "unknown"
        }
        val temperatureC = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            ?.takeIf { it != Int.MIN_VALUE }?.let { it / 10.0 }
        val voltageMv = intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)?.takeIf { it >= 0 }

        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val chargeCounterUah = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
            ?.takeIf { it != Int.MIN_VALUE && it != 0 }
        val currentNowUa = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            ?.takeIf { it != Int.MIN_VALUE }

        return linkedMapOf(
            "level"              to pct,
            "state"              to state,
            "temperature_c"      to temperatureC,
            "voltage_mv"         to voltageMv,
            "charge_counter_uah" to chargeCounterUah,
            "current_now_ua"     to currentNowUa,
            "timestamp"          to java.time.Instant.now().toString(),
        )
    }

    private fun collectDeviceInfo(context: Context): Map<String, Any?> {
        val memTotalKb = try {
            java.io.File("/proc/meminfo").readLines()
                .firstOrNull { it.startsWith("MemTotal") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()
        } catch (_: Exception) { null }
        val cpuInfo = try { java.io.File("/proc/cpuinfo").readText() } catch (_: Exception) { "" }
        val cpuHardware = cpuInfo.lines()
            .firstOrNull { it.startsWith("Hardware") }?.substringAfter(":")?.trim()
        val cpuFreqsKhz = (0 until Runtime.getRuntime().availableProcessors()).map { idx ->
            try {
                java.io.File("/sys/devices/system/cpu/cpu$idx/cpufreq/cpuinfo_max_freq")
                    .readText().trim().toLongOrNull()
            } catch (_: Exception) { null }
        }
        val internalStat = runCatching { StatFs(context.filesDir.absolutePath) }.getOrNull()
        val storageTotalBytes = internalStat?.let { it.blockSizeLong * it.blockCountLong }
        val storageFreeBytes  = internalStat?.let { it.blockSizeLong * it.availableBlocksLong }

        return linkedMapOf(
            "model"               to Build.MODEL,
            "manufacturer"        to Build.MANUFACTURER,
            "board"               to Build.BOARD,
            "hardware"            to Build.HARDWARE,
            "cpu_hardware"        to cpuHardware,
            "cpu_cores"           to Runtime.getRuntime().availableProcessors(),
            "cpu_max_freqs_khz"   to cpuFreqsKhz,
            "ram_total_kb"        to memTotalKb,
            "storage_total_bytes" to storageTotalBytes,
            "storage_free_bytes"  to storageFreeBytes,
            "android_version"     to Build.VERSION.RELEASE,
            "sdk_int"             to Build.VERSION.SDK_INT,
            "abi"                 to Build.SUPPORTED_ABIS.firstOrNull(),
            "platform"            to "Android",
        )
    }
}
