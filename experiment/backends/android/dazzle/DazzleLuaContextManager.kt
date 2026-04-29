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

import dev.dazzle.sdk.Dazzle
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.StreamKey

/**
 * Optimized Valkey [StorageBackend] that uses Lua scripting + directPipeline
 * to demonstrate that Valkey's capabilities not only provide richer primitives
 * but also **faster retrieval** than any other backend when used correctly.
 *
 * The naive ValkeyContextManager issues 6-8 separate directCommand calls per
 * buildContextBlock (XREVRANGE + 5 HGETs + ZRANGEBYSCORE), each crossing the
 * event-loop pipe independently → ~4.4 ms total.
 *
 * This optimized version:
 *   1. **Writes** use directPipeline to batch all ingestion ops into ONE
 *      pipe dispatch (1 round-trip instead of 6-8).
 *   2. **Reads** use a single EVAL Lua script that executes all queries
 *      server-side and returns the assembled context block as a single
 *      string (1 round-trip instead of 6-8).
 *
 * Expected improvement: retrieval drops from ~4.4 ms to ~500-800 µs,
 * making Valkey FASTER than SQLite (1.4 ms) while retaining the full
 * capability set (HFE, HLL, Geo, Pub/Sub, Streams, etc.).
 *
 * This is the paper's key demonstration: "Valkey's scripting capability
 * is not just a feature checkbox — it directly enables a 5-8× retrieval
 * speedup that simpler backends cannot achieve."
 */
class DazzleLuaContextManager : StorageBackend {

    override val backendName: String = "Dazzle-Lua"

    private val dazzle: Dazzle = DazzleServer.client()

    // Keep the typed primitives for writes and for the non-Lua fallbacks
    private val readings  = dazzle.stream("sensor:readings")
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")
    private val decisions = dazzle.list("agent:decisions")

    // ── Lua scripts (loaded once, cached by SHA) ──────────────────────────

    // Lua script that fetches ALL data in ONE round-trip and returns raw
    // values as a flat array. Kotlin formats the output (handling Unicode
    // chars like ° and → that break RESP byte-count parsing).
    private val contextBlockScript = dazzle.script("""
        local result = {}
        local entries = redis.call('XREVRANGE', KEYS[1], '+', '-', 'COUNT', 10)
        local temps = {}
        for i = #entries, 1, -1 do
            local fields = entries[i][2]
            for j = 1, #fields, 2 do
                if fields[j] == 'temp' then temps[#temps+1] = fields[j+1] end
            end
        end
        result[1] = table.concat(temps, ',')
        local s = redis.call('HMGET', KEYS[2], 'count', 'temp_sum', 'min_temp', 'max_temp', 'anomaly_count')
        result[2] = s[1] or '0'
        result[3] = s[2] or '0'
        result[4] = s[3] or '0'
        result[5] = s[4] or '0'
        result[6] = s[5] or '0'
        local anoms = redis.call('ZRANGEBYSCORE', KEYS[3], ARGV[1], ARGV[2])
        result[7] = table.concat(anoms, ',')
        return result
    """.trimIndent())

    private val synthesisScript = dazzle.script("""
        local result = {}
        local s = redis.call('HMGET', KEYS[1], 'count', 'temp_sum', 'min_temp', 'max_temp', 'anomaly_count')
        result[1] = s[1] or '0'
        result[2] = s[2] or '0'
        result[3] = s[3] or '0'
        result[4] = s[4] or '0'
        result[5] = s[5] or '0'
        local anoms = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', '+inf')
        result[6] = table.concat(anoms, ',')
        local decs = redis.call('LRANGE', KEYS[3], 0, -1)
        result[7] = table.concat(decs, '|')
        return result
    """.trimIndent())

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        readings.deleteKey()
        stats.delete()
        anomalies.deleteKey()
        decisions.deleteKey()
        for (i in 0..9) dazzle.hash("agent:checkpoint:$i").delete()
    }

    // ── Ingest (batched via directPipeline) ───────────────────────────────

    override fun ingest(reading: SensorReading) {
        // Batch all writes into one pipeline dispatch
        val commands = mutableListOf<List<String>>()

        commands.add(listOf(
            "XADD", "sensor:readings", "MAXLEN", "~", "200", "*",
            "temp", reading.tempC.toString(),
            "humidity", reading.humidity.toString(),
            "minute", reading.minute.toString(),
            "anomalous", if (reading.anomalous) "1" else "0",
        ))
        commands.add(listOf("HINCRBYFLOAT", "sensor:stats", "temp_sum", reading.tempC.toString()))
        commands.add(listOf("HINCRBY", "sensor:stats", "count", "1"))
        commands.add(listOf("HSET", "sensor:stats", "latest_temp", reading.tempC.toString()))
        commands.add(listOf("HSET", "sensor:stats", "latest_minute", reading.minute.toString()))

        if (reading.anomalous) {
            commands.add(listOf("ZADD", "sensor:anomalies", reading.minute.toString(), reading.minute.toString()))
            commands.add(listOf("HINCRBY", "sensor:stats", "anomaly_count", "1"))
        }

        DazzleServer.directPipeline(commands)

        // Min/max still needs read-then-write (can't pipeline conditional logic)
        val curMin = stats.get("min_temp")?.toDoubleOrNull()
        if (curMin == null || reading.tempC < curMin) {
            stats.set("min_temp", reading.tempC.toString())
        }
        val curMax = stats.get("max_temp")?.toDoubleOrNull()
        if (curMax == null || reading.tempC > curMax) {
            stats.set("max_temp", reading.tempC.toString())
        }
    }

    // ── Context block (1 Lua EVAL = 1 pipe round-trip) ────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val windowStart = maxOf(0, currentMinute - windowMinutes)
        val raw = contextBlockScript.eval(
            keys = listOf("sensor:readings", "sensor:stats", "sensor:anomalies"),
            args = listOf(windowStart.toString(), currentMinute.toString(), windowMinutes.toString()),
        ).asArray().map { it.asBulkOrNull() ?: "" }

        // raw[0] = temps CSV, raw[1..5] = count/sum/min/max/anomCnt, raw[6] = anomaly mins CSV
        val lines = mutableListOf<String>()

        val tempsCsv = raw.getOrNull(0) ?: ""
        if (tempsCsv.isNotEmpty()) {
            val temps = tempsCsv.split(",").mapNotNull { it.toDoubleOrNull() }
            if (temps.isNotEmpty()) {
                val formatted = temps.joinToString(", ") { String.format("%.1f", it) }
                lines += "Last ${temps.size} temperatures (oldest→newest, °C): $formatted"
                lines += "Recent trend: ${computeTrend(temps)}"
            }
        }

        val count = raw.getOrNull(1)?.toIntOrNull() ?: 0
        if (count > 0) {
            val sum = raw.getOrNull(2)?.toDoubleOrNull() ?: 0.0
            val minT = raw.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val maxT = raw.getOrNull(4)?.toDoubleOrNull() ?: 0.0
            val anomCnt = raw.getOrNull(5)?.toIntOrNull() ?: 0
            lines += "Aggregate over $count readings: " +
                "avg=${String.format("%.1f", sum / count)}°C, " +
                "min=${String.format("%.1f", minT)}°C, " +
                "max=${String.format("%.1f", maxT)}°C"
            lines += "Total anomalies detected so far: $anomCnt"
        }

        val anomsCsv = raw.getOrNull(6) ?: ""
        if (anomsCsv.isEmpty()) {
            lines += "No anomalies in the last $windowMinutes minutes."
        } else {
            lines += "Anomalous time indices in the last $windowMinutes minutes " +
                "(minute numbers, not temperatures): [$anomsCsv]"
        }

        return lines.joinToString("\n")
    }

    override fun buildSynthesisContext(): String {
        val raw = synthesisScript.eval(
            keys = listOf("sensor:stats", "sensor:anomalies", "agent:decisions"),
            args = emptyList(),
        ).asArray().map { it.asBulkOrNull() ?: "" }

        // raw[0..4] = count/sum/min/max/anomCnt, raw[5] = anomaly mins CSV, raw[6] = decisions pipe-separated
        val lines = mutableListOf<String>()

        val count = raw.getOrNull(0)?.toIntOrNull() ?: 0
        if (count > 0) {
            val sum = raw.getOrNull(1)?.toDoubleOrNull() ?: 0.0
            val minT = raw.getOrNull(2)?.toDoubleOrNull() ?: 0.0
            val maxT = raw.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val anomCnt = raw.getOrNull(4)?.toIntOrNull() ?: 0
            lines += "=== Full Session Stats ==="
            lines += "Total readings: $count"
            lines += "Temperature range: ${String.format("%.1f", minT)}°C to " +
                "${String.format("%.1f", maxT)}°C " +
                "(avg ${String.format("%.1f", sum / count)}°C)"
            lines += "Total anomalies detected: $anomCnt"
        }

        val anomsCsv = raw.getOrNull(5) ?: ""
        if (anomsCsv.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): [$anomsCsv]"
        }

        val decsPipe = raw.getOrNull(6) ?: ""
        if (decsPipe.isNotEmpty()) {
            val decs = decsPipe.split("|")
            lines += "=== Monitoring Agent Decisions ==="
            for ((idx, decision) in decs.withIndex()) {
                lines += "  Checkpoint ${idx + 1}: $decision"
            }
        }

        return lines.joinToString("\n")
    }

    // ── Decision storage ──────────────────────────────────────────────────

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

    override fun storeCheckpointDecision(
        index: Int,
        minute: Int,
        anomalyDetected: Boolean,
        severity: String,
        trend: String,
    ) {
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} " +
            "severity=$severity trend=$trend"

        DazzleServer.directPipeline(listOf(
            listOf("HSET", "agent:checkpoint:$index",
                "minute", minute.toString(),
                "anomaly", if (anomalyDetected) "1" else "0",
                "severity", severity,
                "trend", trend),
            listOf("RPUSH", "agent:decisions", decision),
        ))
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
