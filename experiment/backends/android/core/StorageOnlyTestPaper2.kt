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

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Process
import android.util.Log
import com.google.gson.GsonBuilder
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.WipeTarget
import java.io.File

/**
 * Quick storage-only test that validates a backend WITHOUT Gemma.
 * Runs in ~1 second: ingests 200 readings, builds context blocks,
 * reports retrieval latency and token count. No inference.
 *
 * Writes a JSON result file to /sdcard/Documents/ with device metadata,
 * per-checkpoint retrieval latencies, and token counts.
 *
 * Usage from adb:
 *   adb shell am start -n dev.dazzle.experiment/.ExperimentActivity \
 *     --ez test_storage_only true --es backend valkey-hll
 */
object StorageOnlyTestPaper2 {

    private const val TAG = "StorageTest"
    private val gson = GsonBuilder().setPrettyPrinting().create()

    fun run(context: Context, backendName: String) {
        Log.i(TAG, "═══ Storage-only test: $backendName ═══")

        // Collect device metadata
        val deviceInfo = collectDeviceInfo(context)

        // The Dazzle server is booted for any backend key that speaks to it
        // (dazzle*, or valkey over TCP). Plain disk-backed backends skip this.
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

        // Vector search test — runs its own server lifecycle, skips the normal
        // ingest/retrieval flow and returns immediately after writing its JSON.
        if (backendName.lowercase() == "dazzle-vector") {
            VectorSearchTest.run(context, context.filesDir)
            return
        }

        // DazzleVectorIoTValkey9Paper2Manager unit tests — validates metadata persistence,
        // faultPct correctness, and MEMORY ASSESSMENT line.
        if (backendName.lowercase() == "dazzle-vector-test") {
            DazzleVectorIoTValkey9Paper2ManagerTest.run(context)
            return
        }

        // Create backend
        val backend: StorageBackend = when (backendName.lowercase()) {
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

        Log.i(TAG, "Backend: ${backend.backendName}")
        backend.flush()

        // Pre-ingest snapshots — single quiesce, internally consistent
        // PSS / RSS pair (see MemoryProbe.Snapshot). The backend-attributable
        // byte count is the primary defensible metric at small N.
        val ramBefore = MemoryProbe.snapshot()
        val backendBytesBefore = backend.backendSizeBytes()
        val ioBefore = getIoWriteBytes()

        // Load dataset
        val dataset = DatasetLoader.load(context)
        Log.i(TAG, "Dataset: ${dataset.readings.size} readings, ${dataset.stats.anomalyCount} anomalies")

        // Ingest all readings (measure per-reading throughput)
        val ingestStart = System.nanoTime()
        for (reading in dataset.readings) {
            backend.ingest(reading)
        }
        val ingestNs = System.nanoTime() - ingestStart
        val ingestMs = ingestNs / 1_000_000.0
        val perIngestUs = ingestNs / (dataset.readings.size * 1_000.0)
        Log.i(TAG, "Ingest: ${dataset.readings.size} readings in ${String.format("%.1f", ingestMs)} ms")

        // Post-ingest snapshots — same protocol as the pre-ingest one.
        val ramAfter = MemoryProbe.snapshot()
        val backendBytesAfter = backend.backendSizeBytes()
        val ioAfter = getIoWriteBytes()

        // Store checkpoint decisions
        for (cpIdx in 0 until dataset.checkpointIndices.size) {
            val cpReading = dataset.readings[dataset.checkpointIndices[cpIdx]]
            val hasAnomaly = dataset.windowHasAnomaly(cpIdx)
            backend.storeCheckpointDecision(
                index = cpIdx,
                minute = cpReading.minute,
                anomalyDetected = hasAnomaly,
                severity = if (hasAnomaly) "high" else "none",
                trend = "stable",
            )
        }

        // Warm-up: 5 untimed retrievals to trigger JIT compilation and
        // fill CPU caches before measuring. Without this, the first few
        // calls are 2-5× slower (JIT compiling the hot path).
        val warmupCp = dataset.readings[dataset.checkpointIndices[4]]
        repeat(5) { backend.buildContextBlock(warmupCp.minute) }

        // Measure retrieval latency: 10 CPs × 5 iterations each = 50 samples
        val latencies = mutableListOf<Double>()
        for (cpIdx in 0 until dataset.checkpointIndices.size) {
            val cpReading = dataset.readings[dataset.checkpointIndices[cpIdx]]
            repeat(5) {
                latencies.add(backend.measureRetrievalLatency(cpReading.minute))
            }
        }
        val sortedLats = latencies.sorted()
        Log.i(TAG, "Retrieval: ${String.format("%.1f", latencies.average())} µs avg (${latencies.size} samples)")

        // Build context block for CP5 (token measurement)
        val cp5Reading = dataset.readings[dataset.checkpointIndices[4]]
        val contextBlock = backend.buildContextBlock(cp5Reading.minute)
        val contextTokensEst = contextBlock.length / 4
        Log.i(TAG, "Context block CP5 (${contextBlock.length} chars, ~$contextTokensEst tokens)")

        // Build synthesis context
        val synthContext = backend.buildSynthesisContext()
        val synthTokensEst = synthContext.length / 4

        // ── Save JSON result ─────────────────────────────────────────────
        val result = linkedMapOf<String, Any?>(
            "type" to "storage_only",
            "timestamp" to java.time.Instant.now().toString(),
            "device" to deviceInfo,
            "backend" to backend.backendName,
            "backend_key" to backendName.lowercase(),
            "readings_count" to dataset.readings.size,
            "ingest_total_ms" to ingestMs,
            "per_ingest_us" to perIngestUs,
            "retrieval_samples" to latencies.size,
            "retrieval_latencies_us" to latencies,
            "avg_retrieval_us" to latencies.average(),
            "median_retrieval_us" to sortedLats[sortedLats.size / 2],
            "min_retrieval_us" to sortedLats.first(),
            "max_retrieval_us" to sortedLats.last(),
            "p50_retrieval_us" to sortedLats[sortedLats.size / 2],
            "p95_retrieval_us" to sortedLats[minOf((sortedLats.size * 0.95).toInt(), sortedLats.size - 1)],
            "context_chars" to contextBlock.length,
            "context_tokens_est" to contextTokensEst,
            "synth_chars" to synthContext.length,
            "synth_tokens_est" to synthTokensEst,
            "ram_before_kb" to ramBefore.primaryKb,
            "ram_after_kb" to ramAfter.primaryKb,
            "ram_delta_kb" to (if (ramAfter.primaryKb >= 0 && ramBefore.primaryKb >= 0)
                ramAfter.primaryKb - ramBefore.primaryKb else null),
            "ram_before_pss_kb" to ramBefore.pssKb,
            "ram_after_pss_kb" to ramAfter.pssKb,
            "ram_delta_pss_kb" to (if (ramAfter.pssKb >= 0 && ramBefore.pssKb >= 0)
                ramAfter.pssKb - ramBefore.pssKb else null),
            "ram_before_rss_kb" to ramBefore.rssKb,
            "ram_after_rss_kb" to ramAfter.rssKb,
            "ram_delta_rss_kb" to (if (ramAfter.rssKb >= 0 && ramBefore.rssKb >= 0)
                ramAfter.rssKb - ramBefore.rssKb else null),
            "ram_metric" to ramAfter.metric,
            "backend_size_method" to backend.backendSizeMethod,
            "backend_size_before_bytes" to backendBytesBefore,
            "backend_size_after_bytes" to backendBytesAfter,
            "backend_size_delta_bytes" to (if (backendBytesAfter >= 0 && backendBytesBefore >= 0)
                backendBytesAfter - backendBytesBefore else null),
            "io_write_bytes_before" to ioBefore,
            "io_write_bytes_after" to ioAfter,
            "io_write_bytes_delta" to (if (ioAfter >= 0 && ioBefore >= 0) ioAfter - ioBefore else null),
        )

        val json = gson.toJson(result)
        val ts = System.currentTimeMillis()
        val safeBackend = backendName.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        val fileName = "storageonly_${safeBackend}_${ts}.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fileName)
        } catch (_: Exception) {
            File(context.filesDir, fileName)
        }
        file.writeText(json)
        Log.i(TAG, "JSON saved: ${file.absolutePath}")

        Log.i(TAG, "═══ RESULT: ${backend.backendName} ═══")
        Log.i(TAG, "  Ingest:      ${String.format("%.1f", ingestMs)} ms (${dataset.readings.size} readings)")
        Log.i(TAG, "  Per-ingest:  ${String.format("%.1f", perIngestUs)} µs/reading")
        Log.i(TAG, "  Retrieval:   ${String.format("%.1f", latencies.average())} µs avg")
        Log.i(TAG, "  P50/P95:     ${String.format("%.1f", sortedLats[sortedLats.size / 2])} / ${String.format("%.1f", sortedLats[minOf((sortedLats.size * 0.95).toInt(), sortedLats.size - 1)])} µs")
        Log.i(TAG, "  CP5 tokens:  ~$contextTokensEst")
        Log.i(TAG, "  Synth tokens: ~$synthTokensEst")
        Log.i(TAG, "  Backend size: ${backendBytesAfter} bytes (Δ ${backendBytesAfter - backendBytesBefore}, ${backend.backendSizeMethod})")
        Log.i(TAG, "  RAM delta:   ${(ramAfter.primaryKb - ramBefore.primaryKb)} KB (${ramAfter.metric}, dominated by GC noise at small N)")
        Log.i(TAG, "  IO writes:   ${if (ioAfter >= 0 && ioBefore >= 0) "${ioAfter - ioBefore} bytes" else "N/A"}")
        Log.i(TAG, "═══ DONE ═══")
    }

    /** Collect device hardware metadata. */
    private fun collectDeviceInfo(context: Context): Map<String, Any?> {
        val memTotalKb = try {
            File("/proc/meminfo").readLines()
                .firstOrNull { it.startsWith("MemTotal") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()
        } catch (_: Exception) { null }

        val cpuInfo = try {
            File("/proc/cpuinfo").readText()
        } catch (_: Exception) { "" }
        val cpuHardware = cpuInfo.lines()
            .firstOrNull { it.startsWith("Hardware") }
            ?.substringAfter(":")?.trim()
        val cpuCores = Runtime.getRuntime().availableProcessors()

        return linkedMapOf(
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "board" to Build.BOARD,
            "hardware" to Build.HARDWARE,
            "cpu_hardware" to cpuHardware,
            "cpu_cores" to cpuCores,
            "ram_total_kb" to memTotalKb,
            "android_version" to Build.VERSION.RELEASE,
            "sdk_int" to Build.VERSION.SDK_INT,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
        )
    }

    /** Read cumulative write bytes from /proc/self/io. */
    private fun getIoWriteBytes(): Long = try {
        File("/proc/self/io").readLines()
            .firstOrNull { it.startsWith("write_bytes") }
            ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull() ?: -1
    } catch (_: Exception) { -1 }
}
