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

/**
 * In-memory [StorageBackend] using plain Kotlin collections.
 *
 * This is the "no database at all" baseline for the paper. It stores
 * everything in [HashMap]s and [ArrayList]s — zero persistence, zero
 * overhead, zero library dependency. The purpose is to show that raw
 * retrieval latency is dominated by computation (context block string
 * building), not by the storage engine, and that Valkey's value
 * proposition is its capabilities (streams, sorted sets, HFE, etc.)
 * rather than raw speed.
 *
 * Expected result: fastest retrieval of all backends, identical
 * recall / FPR / synthesis because the context block is byte-identical.
 *
 * Limitations vs Valkey:
 *   - No persistence — crash = data loss
 *   - No auto-trim — we manual-trim in code (same as SQLite)
 *   - No atomic operations — single-threaded only
 *   - No TTL / expiration
 *   - No range queries on score — we linear-scan the anomaly list
 *   - No pub/sub, scripting, transactions
 */
class InMemoryContextManager : StorageBackend {

    override val backendName: String = "InMemory"

    // Data structures that mirror Valkey's primitives
    private val readings     = ArrayList<ReadingEntry>(210)
    private val stats        = HashMap<String, Double>()
    private val anomalyMins  = ArrayList<Int>()              // sorted by minute
    private val decisions    = ArrayList<String>()            // ordered by CP index
    private val checkpoints  = HashMap<Int, CheckpointEntry>()

    private data class ReadingEntry(
        val minute: Int,
        val temp: Double,
        val humidity: Double,
        val anomalous: Boolean,
    )

    private data class CheckpointEntry(
        val minute: Int,
        val anomaly: Boolean,
        val severity: String,
        val trend: String,
    )

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        readings.clear()
        stats.clear()
        anomalyMins.clear()
        decisions.clear()
        checkpoints.clear()
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        readings.add(ReadingEntry(
            minute    = reading.minute,
            temp      = reading.tempC,
            humidity  = reading.humidity,
            anomalous = reading.anomalous,
        ))

        // Trim to 200 — equivalent to Valkey MAXLEN ~200
        if (readings.size > 210) {
            readings.subList(0, readings.size - 200).clear()
        }

        // Running stats
        stats["temp_sum"] = (stats["temp_sum"] ?: 0.0) + reading.tempC
        stats["count"]    = (stats["count"] ?: 0.0) + 1.0
        stats["latest_temp"]   = reading.tempC
        stats["latest_minute"] = reading.minute.toDouble()

        val curMin = stats["min_temp"]
        if (curMin == null || reading.tempC < curMin) {
            stats["min_temp"] = reading.tempC
        }
        val curMax = stats["max_temp"]
        if (curMax == null || reading.tempC > curMax) {
            stats["max_temp"] = reading.tempC
        }

        if (reading.anomalous) {
            if (reading.minute !in anomalyMins) {
                // Insert sorted
                val idx = anomalyMins.binarySearch(reading.minute).let {
                    if (it < 0) -(it + 1) else it
                }
                anomalyMins.add(idx, reading.minute)
            }
            stats["anomaly_count"] = (stats["anomaly_count"] ?: 0.0) + 1.0
        }
    }

    // ── Context block (byte-identical to Valkey/SQLite) ───────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        // Last 10 readings (oldest → newest)
        val recent = readings.takeLast(10)
        val recentTemps = recent.map { it.temp }

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
        val windowAnomalies = anomalyMins.filter { it in windowStart..currentMinute }

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

        if (anomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${anomalyMins.joinToString(", ")}]"
        }

        if (decisions.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            for ((idx, decision) in decisions.withIndex()) {
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

        checkpoints[index] = CheckpointEntry(
            minute  = minute,
            anomaly = anomalyDetected,
            severity = severity,
            trend   = trend,
        )

        // Ensure decisions list is large enough
        while (decisions.size <= index) decisions.add("")
        decisions[index] = decision
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
        val count = stats["count"]?.toInt() ?: return null
        if (count == 0) return null
        val sum      = stats["temp_sum"] ?: 0.0
        val minTemp  = stats["min_temp"] ?: 0.0
        val maxTemp  = stats["max_temp"] ?: 0.0
        val anomCnt  = stats["anomaly_count"]?.toInt() ?: 0
        return RunningStats(
            count        = count,
            avgTemp      = sum / count,
            minTemp      = minTemp,
            maxTemp      = maxTemp,
            anomalyCount = anomCnt,
        )
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

    override val backendSizeMethod: String = "inmemory:struct_estimate"

    /**
     * Conservative byte estimate of the live Kotlin objects this backend
     * keeps. The JVM lays each object behind a 16-byte header on 64-bit
     * ART, plus aligned-to-8 payload, so the per-entry numbers below are
     * lower bounds that ignore HashMap / ArrayList growth slack.
     *
     * Components:
     *   - ReadingEntry    : 16 hdr + 4 minute + 8 temp + 8 humidity + 1 anom + pad ≈ 40
     *   - anomalyMins     : 4 bytes per Int (boxed → ~16 each, but ArrayList<Int>
     *                       holds Integer references; conservatively count 16)
     *   - decisions       : variable, sum of String char counts × 2 + 40 hdr each
     *   - checkpoints     : ~80 per CheckpointEntry incl. severity/trend strings
     *   - stats           : HashMap entry node ~48 + key + value ≈ 80 each
     */
    override fun backendSizeBytes(): Long {
        var total = 0L
        total += readings.size.toLong() * 40L
        total += anomalyMins.size.toLong() * 16L
        total += decisions.sumOf { 40L + it.length.toLong() * 2L }
        total += checkpoints.size.toLong() * 80L
        total += stats.entries.sumOf { 80L + it.key.length.toLong() * 2L }
        return total
    }
}
