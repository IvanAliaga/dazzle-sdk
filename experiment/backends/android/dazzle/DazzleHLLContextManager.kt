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
 * Valkey backend demonstrating HyperLogLog (HLL) for token-efficient
 * context blocks — a probabilistic data structure exclusive to Valkey
 * that estimates cardinality with ~0.81% error in a fixed 12 KB footprint.
 *
 * Instead of listing every anomaly minute individually in the context
 * (which grows linearly with N anomalies and can consume hundreds of
 * tokens), this backend uses HLL to report:
 *   "~11 anomalies detected (estimated via HLL, ±0.81%)"
 * in a CONSTANT number of tokens regardless of data volume.
 *
 * Additionally, it tracks cardinality of distinct anomaly TYPES (spike,
 * drift, dropout, oscillation) via a separate HLL, adding:
 *   "4 distinct anomaly patterns observed"
 * to the context — information that helps the model's synthesis without
 * consuming tokens proportional to the event count.
 *
 * Token savings at scale:
 *   N=200 readings, 11 anomalies:
 *     naive:  "Anomalous time indices: [45, 94, 95, 96, 110, ...]" → ~30 tokens
 *     HLL:    "~11 anomalies detected, 4 distinct patterns" → ~10 tokens
 *   N=20K readings, 1000+ anomalies:
 *     naive:  "[45, 94, 95, ..., 19997]" → ~2000+ tokens
 *     HLL:    "~1047 anomalies detected, 4 distinct patterns" → ~10 tokens (CONSTANT)
 *
 * This is the paper's token efficiency demonstration.
 */
class DazzleHLLContextManager : StorageBackend {

    override val backendName: String = "Dazzle-HLL"

    private val dazzle: Dazzle = DazzleServer.client()
    private val readings  = dazzle.stream("sensor:readings")
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")
    private val decisions = dazzle.list("agent:decisions")
    // HLL for cardinality estimation
    private val anomalyHLL = dazzle.hyperLogLog("sensor:anomaly_hll")
    private val anomalyTypeHLL = dazzle.hyperLogLog("sensor:anomaly_type_hll")

    override fun flush() {
        readings.deleteKey()
        stats.delete()
        anomalies.deleteKey()
        decisions.deleteKey()
        anomalyHLL.deleteKey()
        anomalyTypeHLL.deleteKey()
        for (i in 0..9) dazzle.hash("agent:checkpoint:$i").delete()
    }

    override fun ingest(reading: SensorReading) {
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

        stats.incrByFloat("temp_sum", reading.tempC)
        stats.incrBy("count", 1)
        stats.set("latest_temp", reading.tempC.toString())
        stats.set("latest_minute", reading.minute.toString())

        val curMin = stats.get("min_temp")?.toDoubleOrNull()
        if (curMin == null || reading.tempC < curMin) {
            stats.set("min_temp", reading.tempC.toString())
        }
        val curMax = stats.get("max_temp")?.toDoubleOrNull()
        if (curMax == null || reading.tempC > curMax) {
            stats.set("max_temp", reading.tempC.toString())
        }

        if (reading.anomalous) {
            anomalies.add(score = reading.minute.toDouble(), member = reading.minute.toString())
            stats.incrBy("anomaly_count", 1)

            // HLL: track the anomaly minute as a unique element
            anomalyHLL.add(reading.minute.toString())

            // HLL: classify the anomaly type and track distinct types
            val anomalyType = when {
                reading.tempC > 32.0 -> "spike_high"
                reading.tempC > 28.0 -> "spike_moderate"
                reading.tempC < 2.0  -> "dropout_severe"
                reading.tempC < 5.0  -> "dropout"
                else                  -> "oscillation"
            }
            anomalyTypeHLL.add(anomalyType)
        }
    }

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        val entries = readings.revRange(count = 10)
        val recentTemps = entries
            .mapNotNull { it.fields["temp"]?.toDoubleOrNull() }
            .reversed()
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

            // HLL: report cardinality instead of listing all anomalies
            val uniqueAnomalies = anomalyHLL.count()
            val distinctTypes = anomalyTypeHLL.count()
            lines += "Total anomalies detected so far: ~$uniqueAnomalies (HLL estimate, $distinctTypes distinct patterns)"
        }

        val windowStart = maxOf(0, currentMinute - windowMinutes)
        val windowAnomalies = anomalies
            .rangeByScore(min = windowStart.toDouble(), max = currentMinute.toDouble())
        if (windowAnomalies.isEmpty()) {
            lines += "No anomalies in the last $windowMinutes minutes."
        } else {
            // Still list window anomalies (small, bounded by window size)
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

            // HLL: compact cardinality instead of full list
            val uniqueAnomalies = anomalyHLL.count()
            val distinctTypes = anomalyTypeHLL.count()
            lines += "Total anomalies detected: ~$uniqueAnomalies ($distinctTypes distinct anomaly patterns)"
            // NOTE: we deliberately DO NOT list all anomaly minutes here.
            // That's the whole point — HLL gives O(1) token count for the
            // global summary while the sorted set still handles per-window
            // queries. At 20K readings this saves ~2000 tokens.
        }

        val decisionLines = decisions.range(0, -1)
        if (decisionLines.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            for ((idx, decision) in decisionLines.withIndex()) {
                lines += "  Checkpoint ${idx + 1}: $decision"
            }
        }

        return lines.joinToString("\n")
    }

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

    // ── Private helpers ───────────────────────────────────────────────────

    private data class RunningStats(
        val count: Int, val avgTemp: Double, val minTemp: Double,
        val maxTemp: Double, val anomalyCount: Int,
    )

    private fun readStats(): RunningStats? {
        // One snapshot-cache HMGET (Phase 1) instead of five pipe HGETs —
        // cuts the retrieval-time FFI crossings from 5 to 1.  Matches the
        // readStats pattern in DazzleContextManager.
        val v = stats.mGetDirect(
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count",
        )
        val count = v[0]?.toIntOrNull() ?: return null
        if (count == 0) return null
        return RunningStats(
            count        = count,
            avgTemp      = (v[1]?.toDoubleOrNull() ?: 0.0) / count,
            minTemp      = v[2]?.toDoubleOrNull() ?: 0.0,
            maxTemp      = v[3]?.toDoubleOrNull() ?: 0.0,
            anomalyCount = v[4]?.toIntOrNull() ?: 0,
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
            slope > 0.15 -> "increasing"
            slope < -0.15 -> "decreasing"
            else -> "stable"
        }
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
}
