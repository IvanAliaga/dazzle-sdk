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
 * Valkey backend demonstrating Hash Field Expiration (HFE) — a Valkey 8
 * exclusive capability that NO other embedded database offers.
 *
 * HFE lets each field inside a hash have its own independent TTL. For the
 * agent memory use case, this means:
 *   - Old checkpoint decisions automatically expire after N seconds
 *   - The synthesis at CP10 only sees RECENT decisions, not the full
 *     accumulated history
 *   - No manual cleanup code, no CRON job, no expiration column
 *
 * Demonstration: each agent decision field gets a TTL proportional to
 * how "old" it is. At synthesis time, expired decisions are automatically
 * invisible — the model sees a cleaner, more focused context.
 *
 * This is the paper's capability demonstration: "HFE produces a naturally
 * decaying agent memory without any application code — SQLite, RocksDB,
 * ObjectBox, and LMDB cannot replicate this without manual purge logic."
 */
class DazzleHFEContextManager : StorageBackend {

    override val backendName: String = "Dazzle-HFE"

    private val dazzle: Dazzle = DazzleServer.client()
    private val readings  = dazzle.stream("sensor:readings")
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")
    private val decisions = dazzle.list("agent:decisions")
    // HFE: decisions stored as hash fields with per-field TTL
    private val agentMemory = dazzle.hash("agent:memory")

    override fun flush() {
        readings.deleteKey()
        stats.delete()
        anomalies.deleteKey()
        decisions.deleteKey()
        agentMemory.delete()
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
            lines += "Total anomalies detected so far: ${s.anomalyCount}"
        }

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

        // HFE DEMONSTRATION: read decisions from the hash with per-field TTL.
        // Expired fields are automatically invisible — the model only sees
        // recent decisions without ANY manual cleanup code.
        val memoryFields = agentMemory.getAll()
        if (memoryFields.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions (with memory decay) ==="
            val sortedDecisions = memoryFields.entries
                .mapNotNull { (k, v) ->
                    val idx = k.removePrefix("cp_").toIntOrNull() ?: return@mapNotNull null
                    idx to v
                }
                .sortedBy { it.first }
            for ((idx, decision) in sortedDecisions) {
                lines += "  Checkpoint ${idx + 1}: $decision"
            }
            // Also note how many decisions have expired
            val totalStored = decisions.length()
            val visible = sortedDecisions.size
            if (totalStored > visible) {
                lines += "  (${totalStored - visible} older decisions auto-expired via HFE)"
            }
        }

        // Fallback: also include the full list for compatibility
        if (memoryFields.isEmpty()) {
            val decisionLines = decisions.range(0, -1)
            if (decisionLines.isNotEmpty()) {
                lines += "=== Monitoring Agent Decisions ==="
                for ((idx, decision) in decisionLines.withIndex()) {
                    lines += "  Checkpoint ${idx + 1}: $decision"
                }
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

        // HFE: store the decision as a hash field WITH a TTL.
        // Older decisions get shorter TTLs so they expire sooner.
        // This simulates "agent memory decay" — the agent naturally
        // forgets old decisions without any cleanup code.
        agentMemory.set("cp_$index", decision)
        // TTL: 120 seconds for recent, scaling down for older checkpoints
        // CP0 (oldest) gets 30s, CP9 (newest) gets 120s
        val ttlSeconds = 30L + (index * 10L)
        agentMemory.expireField("cp_$index", ttlSeconds)
    }

    // ── Private helpers ───────────────────────────────────────────────────

    private data class RunningStats(
        val count: Int, val avgTemp: Double, val minTemp: Double,
        val maxTemp: Double, val anomalyCount: Int,
    )

    private fun readStats(): RunningStats? {
        // Phase 1 snapshot HMGET — collapses five pipe HGETs into a single
        // FFI crossing. Same pattern as DazzleContextManager.readStats.
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
