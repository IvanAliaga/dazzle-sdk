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
import java.io.File

/**
 * RocksDB-based [StorageBackend] for the Sequential Monitoring Agent.
 *
 * RocksDB is Facebook/Meta's LSM-tree embedded KV store — the industry
 * standard for high-write-throughput embedded storage. It's used by
 * MySQL (MyRocks), CockroachDB, TiKV, and many others as their
 * storage engine.
 *
 * This implementation compiles RocksDB from source via NDK (v9.10.2)
 * and wraps it in a minimal JNI bridge. Keys are prefixed to simulate
 * named sub-databases ("readings:", "stats:", etc.) since we use the
 * default column family for simplicity.
 *
 * What RocksDB CAN do that simpler KV stores can't:
 *   - Column families (we don't use them for simplicity)
 *   - Merge operators for atomic read-modify-write
 *   - Prefix bloom filters for fast prefix scans
 *   - Compaction filters for TTL-like expiration
 *   - Snapshot reads for consistent point-in-time views
 *
 * What RocksDB CANNOT do that Valkey can:
 *   - No typed primitives (everything is bytes)
 *   - No auto-trimmed streams
 *   - No sorted-set with score-based range queries
 *   - No per-field TTL (HFE)
 *   - No HyperLogLog / Geo / Pub/Sub / Lua scripting
 */
class RocksDbContextManager(context: Context) : StorageBackend {

    override val backendName: String = "RocksDB"

    private val dbDir = File(context.filesDir, "rocksdb-experiment")
    private var readingCounter = 0L

    init {
        dbDir.mkdirs()
        RocksDbBridge.nativeOpen(dbDir.absolutePath)
    }

    private companion object {
        const val READINGS_CAP = 200
        const val TRIM_BATCH   = 32
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        RocksDbBridge.nativeDeleteWithPrefix("readings:")
        RocksDbBridge.nativeDeleteWithPrefix("stats:")
        RocksDbBridge.nativeDeleteWithPrefix("anomalies:")
        RocksDbBridge.nativeDeleteWithPrefix("decisions:")
        RocksDbBridge.nativeDeleteWithPrefix("checkpoints:")
        readingCounter = 0L
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        val id = readingCounter++
        RocksDbBridge.nativePut(
            "readings:${String.format("%010d", id)}",
            "${reading.minute},${reading.tempC},${reading.humidity},${if (reading.anomalous) 1 else 0}"
        )

        // Trim to ~200 entries. Amortize the prefix-scan: only run it every
        // TRIM_BATCH ingests once we've gone past the soft cap, so the per-
        // ingest cost stays O(1) instead of O(N) (a full LSM iterator scan
        // on every insert pushed N=400 ingest past the 120 s storage_only
        // timeout on Unisoc T760).
        if (readingCounter > READINGS_CAP + TRIM_BATCH &&
            readingCounter % TRIM_BATCH == 0L) {
            val keys = RocksDbBridge.nativeGetKeysWithPrefix("readings:")
            if (keys != null && keys.size > READINGS_CAP) {
                val drop = keys.size - READINGS_CAP
                for (i in 0 until drop) {
                    RocksDbBridge.nativeDelete(keys[i])
                }
            }
        }

        // Running stats
        upsertStat("temp_sum", reading.tempC, increment = true)
        upsertStat("count", 1.0, increment = true)
        upsertStat("latest_temp", reading.tempC, increment = false)
        upsertStat("latest_minute", reading.minute.toDouble(), increment = false)

        val curMin = getStat("min_temp")
        if (curMin == null || reading.tempC < curMin) {
            upsertStat("min_temp", reading.tempC, increment = false)
        }
        val curMax = getStat("max_temp")
        if (curMax == null || reading.tempC > curMax) {
            upsertStat("max_temp", reading.tempC, increment = false)
        }

        if (reading.anomalous) {
            RocksDbBridge.nativePut("anomalies:${reading.minute}", "1")
            upsertStat("anomaly_count", 1.0, increment = true)
        }
    }

    // ── Context block ─────────────────────────────────────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        // Last 10 readings
        val readingKeys = RocksDbBridge.nativeGetKeysWithPrefix("readings:")
        val recentTemps = mutableListOf<Double>()
        if (readingKeys != null && readingKeys.isNotEmpty()) {
            for (k in readingKeys.takeLast(10)) {
                val v = RocksDbBridge.nativeGet(k)
                if (v != null) {
                    val parts = v.split(",")
                    if (parts.size >= 2) recentTemps.add(parts[1].toDoubleOrNull() ?: 0.0)
                }
            }
        }

        if (recentTemps.isNotEmpty()) {
            val formatted = recentTemps.joinToString(", ") { String.format("%.1f", it) }
            lines += "Last ${recentTemps.size} temperatures (oldest→newest, °C): $formatted"
            lines += "Recent trend: ${computeTrend(recentTemps)}"
        }

        val s = readStats()
        if (s != null) {
            lines += "Aggregate over ${s.count} readings: " +
                "avg=${String.format("%.1f", s.avgTemp)}°C, " +
                "min=${String.format("%.1f", s.minTemp)}°C, " +
                "max=${String.format("%.1f", s.maxTemp)}°C"
            lines += "Total anomalies detected so far: ${s.anomalyCount}"
        }

        val windowStart = maxOf(0, currentMinute - windowMinutes)
        val anomalyKeys = RocksDbBridge.nativeGetKeysWithPrefix("anomalies:")
        val windowAnomalies = anomalyKeys
            ?.mapNotNull { it.removePrefix("anomalies:").toIntOrNull() }
            ?.filter { it in windowStart..currentMinute }
            ?.sorted()
            ?: emptyList()

        if (windowAnomalies.isEmpty()) {
            lines += "No anomalies in the last $windowMinutes minutes."
        } else {
            lines += "Anomalous time indices in the last $windowMinutes minutes " +
                "(minute numbers, not temperatures): [${windowAnomalies.joinToString(", ")}]"
        }

        return lines.joinToString("\n")
    }

    override fun buildSynthesisContext(): String {
        val lines = mutableListOf<String>()

        val s = readStats()
        if (s != null) {
            lines += "=== Full Session Stats ==="
            lines += "Total readings: ${s.count}"
            lines += "Temperature range: ${String.format("%.1f", s.minTemp)}°C to " +
                "${String.format("%.1f", s.maxTemp)}°C " +
                "(avg ${String.format("%.1f", s.avgTemp)}°C)"
            lines += "Total anomalies detected: ${s.anomalyCount}"
        }

        val anomalyKeys = RocksDbBridge.nativeGetKeysWithPrefix("anomalies:")
        val allAnomalyMins = anomalyKeys
            ?.mapNotNull { it.removePrefix("anomalies:").toIntOrNull() }
            ?.sorted()
            ?: emptyList()

        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
        }

        val decisionKeys = RocksDbBridge.nativeGetKeysWithPrefix("decisions:")
        val decisionList = decisionKeys
            ?.mapNotNull { k ->
                val idx = k.removePrefix("decisions:").toIntOrNull() ?: return@mapNotNull null
                val decision = RocksDbBridge.nativeGet(k) ?: return@mapNotNull null
                idx to decision
            }
            ?.sortedBy { it.first }
            ?: emptyList()

        if (decisionList.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            for ((idx, decision) in decisionList) {
                lines += "  Checkpoint ${idx + 1}: $decision"
            }
        }

        return lines.joinToString("\n")
    }

    // ── Decision storage ──────────────────────────────────────────────────

    override fun storeCheckpointDecision(
        index: Int,
        minute: Int,
        anomalyDetected: Boolean,
        severity: String,
        trend: String,
    ) {
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} " +
            "severity=$severity trend=$trend"

        RocksDbBridge.nativePut("checkpoints:$index",
            "$minute,${if (anomalyDetected) 1 else 0},$severity,$trend")
        RocksDbBridge.nativePut("decisions:$index", decision)
    }

    // ── Private helpers ───────────────────────────────────────────────────

    private data class RunningStats(
        val count: Int,
        val avgTemp: Double,
        val minTemp: Double,
        val maxTemp: Double,
        val anomalyCount: Int,
    )

    private fun readStats(): RunningStats? {
        val count = getStat("count")?.toInt() ?: return null
        if (count == 0) return null
        return RunningStats(
            count        = count,
            avgTemp      = (getStat("temp_sum") ?: 0.0) / count,
            minTemp      = getStat("min_temp") ?: 0.0,
            maxTemp      = getStat("max_temp") ?: 0.0,
            anomalyCount = getStat("anomaly_count")?.toInt() ?: 0,
        )
    }

    private fun getStat(key: String): Double? =
        RocksDbBridge.nativeGet("stats:$key")?.toDoubleOrNull()

    private fun upsertStat(key: String, value: Double, increment: Boolean) {
        val existing = getStat(key)
        val newVal = if (increment && existing != null) existing + value else value
        RocksDbBridge.nativePut("stats:$key", newVal.toString())
    }

    private fun computeTrend(temps: List<Double>): String {
        if (temps.size < 2) return "stable"
        val n = temps.size
        val meanX = (n - 1) / 2.0
        val meanY = temps.average()
        val num = (0 until n).sumOf { (it - meanX) * (temps[it] - meanY) }
        val den = (0 until n).sumOf { (it - meanX) * (it - meanX) }
        val slope = if (den != 0.0) num / den else 0.0
        return when {
            slope >  0.15 -> "increasing"
            slope < -0.15 -> "decreasing"
            else          -> "stable"
        }
    }

    // ── Footprint accounting ──────────────────────────────────────────────

    override val backendSizeMethod: String = "rocksdb:dir_st_blocks"

    /**
     * Sum on-disk usage across the RocksDB directory. RocksDB writes SST
     * files, WAL log, manifest, options and lock files; we measure them
     * via `st_blocks * 512` so the result matches `du -k` and excludes
     * any sparse-region inflation.
     */
    override fun backendSizeBytes(): Long {
        if (!dbDir.exists()) return 0L
        var total = 0L
        dbDir.walkTopDown().forEach { f ->
            if (f.isFile) {
                try {
                    val st = android.system.Os.stat(f.absolutePath)
                    total += st.st_blocks * 512L
                } catch (_: Exception) {
                    total += f.length()
                }
            }
        }
        return total
    }
}
