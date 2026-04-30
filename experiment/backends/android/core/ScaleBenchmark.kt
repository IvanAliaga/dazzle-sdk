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
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.WipeTarget
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Scale benchmark for the paper's 7 axes.
 *
 * For each backend × each N (number of readings), measures:
 *   - Eje 1: Retrieval latency vs N
 *   - Eje 2: RAM footprint vs N
 *   - Eje 3: Write throughput (ingest µs/reading)
 *   - Eje 4: Concurrent read-write latency under load
 *   - Eje 6: IO impact (flash write bytes)
 *   - Eje 7: Token efficiency vs N (context block token count)
 *
 * Eje 5 (crash recovery) is handled by a separate script that kills
 * and restarts the process.
 *
 * Usage from adb:
 *   adb shell am start -n dev.dazzle.experiment/.ExperimentActivity \
 *     --ez scale_benchmark true --es backend valkey-precompute \
 *     --es scale_counts "200,1000,5000,20000"
 */
class ScaleBenchmark(private val context: Context) {

    private val gson = GsonBuilder().setPrettyPrinting().create()

    companion object {
        private const val TAG = "ScaleBench"
        val DEFAULT_COUNTS = listOf(200, 1000, 5000, 20000, 100000)
    }

    data class ScalePoint(
        val n: Int,
        val retrievalUs: Double,
        val retrievalP50Us: Double,
        val retrievalP95Us: Double,
        val ingestTotalMs: Double,
        val perIngestUs: Double,
        val ramBeforeKb: Long,
        val ramAfterKb: Long,
        val ramDeltaKb: Long,
        val ramBeforePssKb: Long,
        val ramAfterPssKb: Long,
        val ramDeltaPssKb: Long,
        val ramBeforeRssKb: Long,
        val ramAfterRssKb: Long,
        val ramDeltaRssKb: Long,
        val ramMetric: String,
        val backendSizeMethod: String,
        val backendSizeBeforeBytes: Long,
        val backendSizeAfterBytes: Long,
        val backendSizeDeltaBytes: Long,
        val contextChars: Int,
        val contextTokensEst: Int,
        val synthChars: Int,
        val synthTokensEst: Int,
        val ioWriteBytesDelta: Long,
        val concurrentRetrievalUs: Double,
        val concurrentP95Us: Double,
    )

    fun run(
        backendName: String,
        readingCounts: List<Int> = DEFAULT_COUNTS,
    ): List<ScalePoint> {
        Log.i(TAG, "═══ Scale benchmark: $backendName ═══")
        Log.i(TAG, "Counts: $readingCounts")

        val results = mutableListOf<ScalePoint>()
        val dataset = DatasetLoader.load(context)

        for (n in readingCounts) {
            Log.i(TAG, "── N=$n ──")

            // Generate N readings by repeating the 200-reading dataset
            val readings = generateReadings(dataset, n)

            // Fresh backend for each N
            val backend = createBackend(backendName)
            backend.flush()

            // Pre-ingest snapshot. Single quiesce + back-to-back PSS/RSS
            // reads keep ram_delta_kb consistent with ram_delta_pss_kb.
            val snapBefore = MemoryProbe.snapshot()
            val backendSizeBefore = backend.backendSizeBytes()
            val ioBefore = getIoWriteBytes()

            // ── Eje 3: Write throughput ──────────────────────────────────
            val ingestStart = System.nanoTime()
            for (reading in readings) {
                backend.ingest(reading)
            }
            val ingestNs = System.nanoTime() - ingestStart
            val ingestMs = ingestNs / 1_000_000.0
            val perIngestUs = ingestNs / (n * 1_000.0)

            // Store checkpoint decisions (needed for synthesis)
            val cps = (19 until minOf(n, 200) step 20).toList()
            for ((cpIdx, cpEndIdx) in cps.withIndex()) {
                val cpReading = readings[cpEndIdx]
                backend.storeCheckpointDecision(
                    index = cpIdx,
                    minute = cpReading.minute,
                    anomalyDetected = cpReading.anomalous,
                    severity = if (cpReading.anomalous) "high" else "none",
                    trend = "stable",
                )
            }

            // ── Eje 2: RAM footprint ─────────────────────────────────────
            val snapAfter = MemoryProbe.snapshot()
            val backendSizeAfter = backend.backendSizeBytes()
            val ioAfter = getIoWriteBytes()

            // ── Eje 1: Retrieval latency at scale ────────────────────────
            val lastMinute = readings.last().minute
            val latencies = (0 until 20).map {
                backend.measureRetrievalLatency(lastMinute)
            }
            val sorted = latencies.sorted()
            val avgRetrieval = latencies.average()

            // ── Eje 7: Token efficiency ──────────────────────────────────
            val contextBlock = backend.buildContextBlock(lastMinute)
            val synthContext = backend.buildSynthesisContext()

            // ── Eje 4: Concurrent read-write ─────────────────────────────
            val (concAvg, concP95) = measureConcurrent(backend, dataset, lastMinute)

            val ramBefore   = snapBefore.primaryKb
            val ramAfter    = snapAfter.primaryKb
            val ramBeforePss = snapBefore.pssKb
            val ramAfterPss  = snapAfter.pssKb
            val ramBeforeRss = snapBefore.rssKb
            val ramAfterRss  = snapAfter.rssKb
            val ramMetric   = if (snapBefore.pssKb > 0 && snapAfter.pssKb > 0) "pss" else "rss"
            val backendSizeDelta = if (backendSizeAfter >= 0 && backendSizeBefore >= 0)
                backendSizeAfter - backendSizeBefore else -1L

            val point = ScalePoint(
                n = n,
                retrievalUs = avgRetrieval,
                retrievalP50Us = sorted[sorted.size / 2],
                retrievalP95Us = sorted[minOf((sorted.size * 0.95).toInt(), sorted.size - 1)],
                ingestTotalMs = ingestMs,
                perIngestUs = perIngestUs,
                ramBeforeKb = ramBefore,
                ramAfterKb = ramAfter,
                ramDeltaKb = if (ramAfter >= 0 && ramBefore >= 0) ramAfter - ramBefore else -1,
                ramBeforePssKb = ramBeforePss,
                ramAfterPssKb = ramAfterPss,
                ramDeltaPssKb = if (ramAfterPss >= 0 && ramBeforePss >= 0) ramAfterPss - ramBeforePss else -1,
                ramBeforeRssKb = ramBeforeRss,
                ramAfterRssKb = ramAfterRss,
                ramDeltaRssKb = if (ramAfterRss >= 0 && ramBeforeRss >= 0) ramAfterRss - ramBeforeRss else -1,
                ramMetric = ramMetric,
                backendSizeMethod = backend.backendSizeMethod,
                backendSizeBeforeBytes = backendSizeBefore,
                backendSizeAfterBytes = backendSizeAfter,
                backendSizeDeltaBytes = backendSizeDelta,
                contextChars = contextBlock.length,
                contextTokensEst = contextBlock.length / 4,
                synthChars = synthContext.length,
                synthTokensEst = synthContext.length / 4,
                ioWriteBytesDelta = if (ioAfter >= 0 && ioBefore >= 0) ioAfter - ioBefore else -1,
                concurrentRetrievalUs = concAvg,
                concurrentP95Us = concP95,
            )
            results.add(point)

            Log.i(TAG, "  Retrieval: ${String.format("%.1f", avgRetrieval)} µs avg")
            Log.i(TAG, "  Ingest: ${String.format("%.1f", perIngestUs)} µs/reading")
            Log.i(TAG, "  RAM delta: ${point.ramDeltaKb} KB (${ramMetric})")
            Log.i(TAG, "  Backend size delta: ${backendSizeDelta} bytes (${backend.backendSizeMethod})")
            Log.i(TAG, "  Tokens: ~${point.contextTokensEst}")
            Log.i(TAG, "  Concurrent retrieval: ${String.format("%.1f", concAvg)} µs avg")
        }

        saveResults(backendName, results)
        return results
    }

    /**
     * Eje 4: Concurrent read-write test.
     * Writer: continuous ingest at ~1 reading/ms.
     * Reader: buildContextBlock() every ~10ms, measure latency.
     *
     * Uses a bounded iteration count instead of wall-clock duration to
     * avoid hangs when Valkey pipe commands block longer than expected
     * at high N (the writer and reader both serialize on the event-loop
     * pipe lock, so a single slow command stalls the entire test).
     */
    private fun measureConcurrent(
        backend: StorageBackend,
        dataset: Dataset,
        currentMinute: Int,
    ): Pair<Double, Double> {
        val latencies = java.util.concurrent.ConcurrentLinkedQueue<Double>()
        val running = AtomicBoolean(true)

        // Writer: fire-and-forget, bounded to 50 ingest calls
        val writerThread = Thread {
            var count = 0
            while (running.get() && count < 50) {
                try {
                    backend.ingest(dataset.readings[count % dataset.readings.size])
                } catch (_: Exception) { break }
                count++
            }
        }
        writerThread.isDaemon = true
        writerThread.start()

        // Reader: 20 context-block reads, measure each
        val readerThread = Thread {
            var count = 0
            while (running.get() && count < 20) {
                try {
                    val start = System.nanoTime()
                    backend.buildContextBlock(currentMinute)
                    latencies.add((System.nanoTime() - start) / 1_000.0)
                } catch (_: Exception) { break }
                count++
            }
        }
        readerThread.isDaemon = true
        readerThread.start()

        // Hard deadline: if threads don't finish in 10s, abandon them
        readerThread.join(10_000)
        running.set(false)
        writerThread.join(2_000)

        // Interrupt stragglers — daemon flag ensures they die with the process
        writerThread.interrupt()
        readerThread.interrupt()

        val lats = latencies.toList().sorted()
        if (lats.isEmpty()) return Pair(0.0, 0.0)
        return Pair(
            lats.average(),
            lats[minOf((lats.size * 0.95).toInt(), lats.size - 1)],
        )
    }

    /**
     * Generate N sensor readings by repeating the 200-reading dataset.
     * Each cycle shifts minute offsets so they are monotonically increasing.
     */
    private fun generateReadings(dataset: Dataset, n: Int): List<SensorReading> {
        val base = dataset.readings
        if (n <= base.size) return base.subList(0, n)

        val result = ArrayList<SensorReading>(n)
        var cycle = 0
        var total = 0
        while (total < n) {
            val offset = cycle * base.size
            for (r in base) {
                if (total >= n) break
                result.add(SensorReading(
                    minute = r.minute + offset,
                    timestamp = r.timestamp,
                    tempC = r.tempC,
                    humidity = r.humidity,
                    anomalous = r.anomalous,
                ))
                total++
            }
            cycle++
        }
        return result
    }

    private fun createBackend(backendName: String): StorageBackend {
        fun ensureServerRunning() {
            if (!DazzleServer.isRunning()) {
                DazzleServer.start(context, DazzleConfig(
                    port = 6380,
                    persistence = DazzlePersistence.None,
                    wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
                ))
                Thread.sleep(800)
            }
        }
        return when (backendName.lowercase()) {
            "dazzle", "dazzle-lua", "dazzle-pipeline", "dazzle-hfe", "dazzle-hll",
            "dazzle-precompute", "dazzle-incremental" -> {
                ensureServerRunning()
                when (backendName.lowercase()) {
                    "dazzle"             -> DazzleContextManager()
                    "dazzle-lua"         -> DazzleLuaContextManager()
                    "dazzle-pipeline"    -> DazzlePipelineContextManager()
                    "dazzle-hfe"         -> DazzleHFEContextManager()
                    "dazzle-hll"         -> DazzleHLLContextManager()
                    "dazzle-precompute"  -> DazzlePrecomputeIoTManager()
                    "dazzle-incremental" -> DazzleIncrementalIoTManager()
                    else -> throw IllegalStateException()
                }
            }
            "valkey"    -> { ensureServerRunning(); ValkeyContextManager() }
            "sqlite"    -> SqliteContextManager(context)
            "sqlite-optimized" -> SqliteOptimizedContextManager(context)
            "sqlite-precompute" -> SqlitePrecomputeContextManager(context)
            "objectbox" -> ObjectBoxContextManager(context)
            "lmdb"      -> LmdbContextManager(context)
            "rocksdb"   -> RocksDbContextManager(context)
            "inmemory"  -> InMemoryContextManager()
            else -> throw IllegalArgumentException("Unknown backend: $backendName")
        }
    }

    private fun saveResults(backendName: String, points: List<ScalePoint>) {
        val memTotalKb = try {
            File("/proc/meminfo").readLines()
                .firstOrNull { it.startsWith("MemTotal") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()
        } catch (_: Exception) { null }

        val result = linkedMapOf<String, Any?>(
            "type" to "scale_benchmark",
            "timestamp" to java.time.Instant.now().toString(),
            "backend" to backendName,
            "device" to linkedMapOf(
                "model" to Build.MODEL,
                "manufacturer" to Build.MANUFACTURER,
                "board" to Build.BOARD,
                "ram_total_kb" to memTotalKb,
                "android_version" to Build.VERSION.RELEASE,
                "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
            ),
            "scale_points" to points.map { p ->
                linkedMapOf(
                    "n" to p.n,
                    "retrieval_avg_us" to p.retrievalUs,
                    "retrieval_p50_us" to p.retrievalP50Us,
                    "retrieval_p95_us" to p.retrievalP95Us,
                    "ingest_total_ms" to p.ingestTotalMs,
                    "per_ingest_us" to p.perIngestUs,
                    "ram_before_kb" to p.ramBeforeKb,
                    "ram_after_kb" to p.ramAfterKb,
                    "ram_delta_kb" to p.ramDeltaKb,
                    "ram_before_pss_kb" to p.ramBeforePssKb,
                    "ram_after_pss_kb" to p.ramAfterPssKb,
                    "ram_delta_pss_kb" to p.ramDeltaPssKb,
                    "ram_before_rss_kb" to p.ramBeforeRssKb,
                    "ram_after_rss_kb" to p.ramAfterRssKb,
                    "ram_delta_rss_kb" to p.ramDeltaRssKb,
                    "ram_metric" to p.ramMetric,
                    "backend_size_method" to p.backendSizeMethod,
                    "backend_size_before_bytes" to p.backendSizeBeforeBytes,
                    "backend_size_after_bytes" to p.backendSizeAfterBytes,
                    "backend_size_delta_bytes" to p.backendSizeDeltaBytes,
                    "context_chars" to p.contextChars,
                    "context_tokens_est" to p.contextTokensEst,
                    "synth_chars" to p.synthChars,
                    "synth_tokens_est" to p.synthTokensEst,
                    "io_write_bytes_delta" to p.ioWriteBytesDelta,
                    "concurrent_retrieval_avg_us" to p.concurrentRetrievalUs,
                    "concurrent_retrieval_p95_us" to p.concurrentP95Us,
                )
            },
        )

        val json = gson.toJson(result)
        val ts = System.currentTimeMillis()
        val safeBackend = backendName.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        val fileName = "scale_${safeBackend}_${ts}.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fileName)
        } catch (_: Exception) {
            File(context.filesDir, fileName)
        }
        file.writeText(json)
        Log.i(TAG, "Scale results saved: ${file.absolutePath}")
    }

    private fun getIoWriteBytes(): Long = try {
        File("/proc/self/io").readLines()
            .firstOrNull { it.startsWith("write_bytes") }
            ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull() ?: -1
    } catch (_: Exception) { -1 }
}
