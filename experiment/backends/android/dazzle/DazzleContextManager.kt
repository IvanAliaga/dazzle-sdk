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

import dev.dazzle.sdk.StreamKey
import dev.dazzle.sdk.Dazzle
import dev.dazzle.sdk.DazzleServer

/**
 * Sensor-specific view of the embedded Valkey instance.
 *
 * Uses the type-safe primitive API exposed by the Dazzle SDK — every
 * operation here is one call on a [Valkey] primitive wrapper, never a
 * raw `directCommand(...)` with a string. The consequence is that this
 * file is ~60% shorter than the pre-refactor version and has zero RESP
 * parsing or string concatenation plumbing.
 *
 * Data layout (aligned byte-for-byte with iOS `SensorContextManager`):
 *
 *   sensor:readings         Stream      MAXLEN ~ 200   full reading history
 *   sensor:stats            Hash                       running aggregates
 *   sensor:anomalies        SortedSet   score = minute confirmed anomaly minutes
 *   agent:decisions         List                       per-checkpoint decisions
 *   agent:checkpoint:{N}    Hash                       per-checkpoint analysis
 */
class DazzleContextManager : StorageBackend {

    override val backendName: String = "Dazzle"

    private val dazzle: Dazzle = DazzleServer.client()

    private val readings  = dazzle.stream("sensor:readings")
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")
    private val decisions = dazzle.list("agent:decisions")

    // ── Ingest ────────────────────────────────────────────────────────────

    /** Ingest one sensor reading. Updates the stream, running stats, and
     *  anomaly sorted set in a single logical step. */
    override fun ingest(reading: SensorReading) {
        // Append to the bounded stream
        readings.add(
            fields = linkedMapOf(
                "temp"      to reading.tempC.toString(),
                "humidity"  to reading.humidity.toString(),
                "minute"    to reading.minute.toString(),
                "anomalous" to if (reading.anomalous) "1" else "0",
            ),
            maxLen = 200,
            trimStrategy = StreamKey.TrimStrategy.APPROX,
        )

        // Running aggregates
        stats.incrByFloat("temp_sum", reading.tempC)
        stats.incrBy("count", 1)
        stats.set("latest_temp", reading.tempC.toString())
        stats.set("latest_minute", reading.minute.toString())

        // Min / max — only write if strictly extending the bound
        val curMin = stats.get("min_temp")?.toDoubleOrNull()
        if (curMin == null || reading.tempC < curMin) {
            stats.set("min_temp", reading.tempC.toString())
        }
        val curMax = stats.get("max_temp")?.toDoubleOrNull()
        if (curMax == null || reading.tempC > curMax) {
            stats.set("max_temp", reading.tempC.toString())
        }

        // Anomaly tracking
        if (reading.anomalous) {
            anomalies.add(score = reading.minute.toDouble(), member = reading.minute.toString())
            stats.incrBy("anomaly_count", 1)
        }
    }

    /** Clear all sensor + agent state (called at the start of each run). */
    override fun flush() {
        readings.deleteKey()
        stats.delete()
        anomalies.deleteKey()
        decisions.deleteKey()
        for (i in 0..9) dazzle.hash("agent:checkpoint:$i").delete()
    }

    // ── Context block — condition B prompt injection ─────────────────────

    /**
     * Natural-language context block that is injected into the Gemma
     * prompt for each checkpoint. The content matches iOS byte-for-byte
     * so both platforms feed the model identical input.
     *
     * Integer minute indices are bracketed with an explicit "not
     * temperatures" hint because the 2B-parameter Gemma edge model was
     * observed to mis-attribute raw integers in the decision log as
     * temperature values during CP10 synthesis (reporting e.g.
     * `max_temp=159.0` where 159 was the minute label of CP8). Typing
     * the integers as time indices eliminates that failure mode.
     */
    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        // Last 10 readings (oldest → newest)
        val entries = readings.revRange(count = 10)
        val recentTemps = entries
            .mapNotNull { it.fields["temp"]?.toDoubleOrNull() }
            .reversed()
        if (recentTemps.isNotEmpty()) {
            val formatted = recentTemps.joinToString(", ") { String.format("%.1f", it) }
            lines += "Last ${recentTemps.size} temperatures (oldest→newest, °C): $formatted"
            lines += "Recent trend: ${computeTrend(recentTemps)}"
        }

        // Aggregate stats via snapshot cache (0 pipes)
        val aggregate = readStats()
        if (aggregate != null) {
            lines += "Aggregate over ${aggregate.count} readings: " +
                "avg=${String.format("%.1f", aggregate.avgTemp)}°C, " +
                "min=${String.format("%.1f", aggregate.minTemp)}°C, " +
                "max=${String.format("%.1f", aggregate.maxTemp)}°C"
            lines += "Total anomalies detected so far: ${aggregate.anomalyCount}"
        }

        // Anomalies in the current window (time indices, not temperatures)
        val windowStart = maxOf(0, currentMinute - windowMinutes)
        val windowAnomalies = anomalies
            .rangeByScore(min = windowStart.toDouble(), max = currentMinute.toDouble())
        if (windowAnomalies.isEmpty()) {
            lines += "No anomalies in the last $windowMinutes minutes."
        } else {
            lines += "Anomalous time indices in the last $windowMinutes minutes " +
                "(minute numbers, not temperatures): [${windowAnomalies.joinToString(", ")}]"
        }

        return lines.joinToString("\n")
    }

    /** Full-session context block used by the CP10 synthesis step. */
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

        val allAnomalyMins = anomalies.rangeByScore(min = 0.0, max = 99999.0)
        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
        }

        // Per-checkpoint decisions — the minute index is intentionally
        // OMITTED from each line (see buildContextBlock doc for the
        // hallucination failure mode this avoids).
        val decisionLines = decisions.range(0, -1)
        if (decisionLines.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            for ((idx, decision) in decisionLines.withIndex()) {
                lines += "  Checkpoint ${idx + 1}: $decision"
            }
        }

        return lines.joinToString("\n")
    }

    // ── Decision storage (Condition B only) ───────────────────────────────

    override fun storeCheckpointDecision(
        index: Int,
        minute: Int,
        anomalyDetected: Boolean,
        severity: String,
        trend: String,
    ) {
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} " +
            "severity=$severity trend=$trend"

        dazzle.hash("agent:checkpoint:$index").setAll(
            linkedMapOf(
                "minute"   to minute.toString(),
                "anomaly"  to if (anomalyDetected) "1" else "0",
                "severity" to severity,
                "trend"    to trend,
            )
        )
        decisions.rpush(decision)
    }

    // ── Retrieval latency measurement ─────────────────────────────────────

    /** Measure round-trip time for buildContextBlock in microseconds. */
    override fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        val end = System.nanoTime()
        return (end - start) / 1_000.0
    }

    // ── Footprint accounting ──────────────────────────────────────────────

    override val backendSizeMethod: String = "valkey:used_memory_dataset"

    override fun backendSizeBytes(): Long {
        val info = dazzle.server().info("memory")
        return info.field("Memory", "used_memory_dataset")?.toLongOrNull()
            ?: info.usedMemoryBytes
            ?: -1L
    }

    override fun backendSizeBreakdown(): Map<String, Long> =
        valkeyMemoryBreakdown(dazzle.server().info("memory"))

    // ── Private helpers ───────────────────────────────────────────────────

    private data class RunningStats(
        val count: Int,
        val avgTemp: Double,
        val minTemp: Double,
        val maxTemp: Double,
        val anomalyCount: Int,
    )

    private fun readStats(): RunningStats? {
        // One snapshot-cache round-trip (Phase 1 directRead) instead of 5 pipe
        // HGETs. mGetDirect returns fields in the order requested; a NULL
        // slot means the field was never written (treated as the default).
        // Falls back to pipe mGet when the key isn't in the snapshot yet.
        val values = stats.mGetDirect(
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count",
        )
        val count = values[0]?.toIntOrNull() ?: return null
        if (count == 0) return null
        val sum     = values[1]?.toDoubleOrNull() ?: 0.0
        val minTemp = values[2]?.toDoubleOrNull() ?: 0.0
        val maxTemp = values[3]?.toDoubleOrNull() ?: 0.0
        val anomCnt = values[4]?.toIntOrNull()    ?: 0
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
}
