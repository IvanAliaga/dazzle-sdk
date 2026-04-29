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
 * LMDB-based [StorageBackend] for the Sequential Monitoring Agent.
 *
 * LMDB (Lightning Memory-Mapped Database) is an embedded B+tree KV store
 * from OpenLDAP. It's compiled from source (2 C files) via the NDK —
 * no pre-built binaries needed. This is the "purest KV store" baseline:
 * no types, no indexes beyond the key sort order, no SQL, no objects.
 *
 * Everything is serialized as key→string pairs across 5 named sub-databases
 * that mirror the Valkey data layout:
 *   - "readings" — key="r:{sequential_id}", value="{minute},{temp},{humidity},{anomalous}"
 *   - "stats"    — key=field_name, value=numeric_string
 *   - "anomalies"— key=minute_string, value="1"
 *   - "decisions"— key=cp_index_string, value=decision_text
 *   - "checkpoints" — key=cp_index_string, value="{minute},{anomaly},{severity},{trend}"
 *
 * What LMDB CANNOT do that Valkey can:
 *   - No auto-trim (manual cleanup needed)
 *   - No atomic increment (read-modify-write)
 *   - No sorted-set range by score (keys are byte-sorted, not score-sorted)
 *   - No per-field TTL, pub/sub, scripting, streams, geo, HLL
 *   - No type system — everything is raw bytes
 */
class LmdbContextManager(context: Context) : StorageBackend {

    override val backendName: String = "LMDB"

    // Start each test from an empty directory — LMDB never shrinks the
    // map file once allocated, so a previous run's footprint would carry
    // over and the storage_only delta would always be ~0. Wiping the
    // directory before nativeOpen() is the only honest way to measure
    // "what does it cost to store 400 readings from cold start".
    private val dbDir = File(context.filesDir, "lmdb-experiment").also {
        if (it.exists()) it.deleteRecursively()
        it.mkdirs()
    }
    private var readingCounter = 0L

    init {
        LmdbBridge.nativeOpen(dbDir.absolutePath, 6, 64)
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        LmdbBridge.nativeDrop("readings")
        LmdbBridge.nativeDrop("stats")
        LmdbBridge.nativeDrop("anomalies")
        LmdbBridge.nativeDrop("decisions")
        LmdbBridge.nativeDrop("checkpoints")
        readingCounter = 0L
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        val id = readingCounter++
        val key = String.format("r:%010d", id)
        val value = "${reading.minute},${reading.tempC},${reading.humidity},${if (reading.anomalous) 1 else 0}"
        LmdbBridge.nativePut("readings", key, value)

        // Trim to ~200 entries
        if (readingCounter > 210) {
            val keys = LmdbBridge.nativeGetAllKeys("readings")
            if (keys != null && keys.size > 200) {
                for (i in 0 until keys.size - 200) {
                    LmdbBridge.nativeDelete("readings", keys[i])
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
            LmdbBridge.nativePut("anomalies", reading.minute.toString(), "1")
            upsertStat("anomaly_count", 1.0, increment = true)
        }
    }

    // ── Context block ─────────────────────────────────────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        // Last 10 readings
        val allKeys = LmdbBridge.nativeGetAllKeys("readings")
        val recentTemps = mutableListOf<Double>()
        if (allKeys != null && allKeys.isNotEmpty()) {
            val last10 = allKeys.takeLast(10)
            for (k in last10) {
                val v = LmdbBridge.nativeGet("readings", k)
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

        // Aggregate stats
        val s = readStats()
        if (s != null) {
            lines += "Aggregate over ${s.count} readings: " +
                "avg=${String.format("%.1f", s.avgTemp)}°C, " +
                "min=${String.format("%.1f", s.minTemp)}°C, " +
                "max=${String.format("%.1f", s.maxTemp)}°C"
            lines += "Total anomalies detected so far: ${s.anomalyCount}"
        }

        // Anomalies in window
        val windowStart = maxOf(0, currentMinute - windowMinutes)
        val anomalyKeys = LmdbBridge.nativeGetAllKeys("anomalies")
        val windowAnomalies = anomalyKeys
            ?.mapNotNull { it.toIntOrNull() }
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

        val anomalyKeys = LmdbBridge.nativeGetAllKeys("anomalies")
        val allAnomalyMins = anomalyKeys
            ?.mapNotNull { it.toIntOrNull() }
            ?.sorted()
            ?: emptyList()

        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
        }

        val decisionKeys = LmdbBridge.nativeGetAllKeys("decisions")
        val decisionList = decisionKeys
            ?.mapNotNull { k ->
                val idx = k.toIntOrNull() ?: return@mapNotNull null
                val decision = LmdbBridge.nativeGet("decisions", k) ?: return@mapNotNull null
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

        LmdbBridge.nativePut("checkpoints", index.toString(),
            "$minute,${if (anomalyDetected) 1 else 0},$severity,$trend")
        LmdbBridge.nativePut("decisions", index.toString(), decision)
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
        LmdbBridge.nativeGet("stats", key)?.toDoubleOrNull()

    private fun upsertStat(key: String, value: Double, increment: Boolean) {
        val existing = getStat(key)
        val newVal = if (increment && existing != null) existing + value else value
        LmdbBridge.nativePut("stats", key, newVal.toString())
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

    override val backendSizeMethod: String = "lmdb:dir_st_blocks"

    /**
     * LMDB pre-allocates the data file to the map size cap (64 MB here),
     * so the apparent file length reports the cap instead of live
     * footprint. We sum `st_blocks * 512` instead — same number `du`
     * reports — so sparse pages of the mapfile that have never been
     * written are correctly counted as zero on disk.
     */
    override fun backendSizeBytes(): Long {
        if (!dbDir.exists()) return 0L
        // Force the kernel to allocate disk blocks for dirty mmap pages.
        // Without this, the env was opened with MDB_NOSYNC|MDB_WRITEMAP so
        // st_blocks stays at 0 and footprint accounting under-reports the
        // entire dataset.
        LmdbBridge.nativeSync(true)
        var total = 0L
        dbDir.walkTopDown().forEach { f ->
            if (f.isFile) {
                try {
                    val st = android.system.Os.stat(f.absolutePath)
                    total += st.st_blocks * 512L
                } catch (_: Exception) {
                    // Fall back to apparent length on platforms without Os.stat
                    total += f.length()
                }
            }
        }
        return total
    }
}
