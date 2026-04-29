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

import dev.dazzle.sdk.Dazzle
import dev.dazzle.sdk.DazzleServer

/**
 * Incremental-context backend — the materialized-view approach taken to its
 * logical conclusion.
 *
 * ## Design
 *
 * `DazzlePrecomputeIoTManager` has the right idea (store derived fields in
 * the hash, read in 1 HMGET), but keeps a rolling-temp ArrayDeque in Kotlin
 * user-space. Under K≥2 concurrent agents that shared state requires
 * `@Synchronized`, which turns every concurrent write into a serial bottleneck
 * (measured: p99 = 58 ms at K=8, 4.7× worse than dazzle-basic).
 *
 * This backend moves ALL mutable state into Valkey:
 *   - `sensor:temps_recent` — LIST, newest-first, max 10 entries
 *   - `sensor:stats`        — Hash, running aggregates + pre-built derived fields
 *   - `sensor:anomalies`    — SortedSet (unchanged)
 *   - `sensor:readings`     — Stream (unchanged)
 *
 * A single Lua script runs on every `ingest()`:
 *   1. XADD to the stream
 *   2. HINCRBYFLOAT / HINCRBY for running aggregates
 *   3. Server-side conditional min/max (no read-then-write from Kotlin)
 *   4. LPUSH + LTRIM to maintain the 10-entry rolling temp list
 *   5. OLS slope over the list → trend string
 *   6. ZRANGEBYSCORE for window anomalies
 *   7. HSET all derived fields atomically
 *
 * `buildContextBlock()` is one `mGetDirect` (same as precompute) — but without
 * any Kotlin-side lock because all mutable data lives in Valkey's C-level mutex.
 *
 * ## Thread-safety
 *
 * No `@Synchronized` anywhere. Concurrent `ingest()` calls from K agents each
 * issue one EVALSHA; Valkey's single-threaded command loop serialises them
 * correctly at the C level, the same way it handles any concurrent writes.
 *
 * ## Expected performance (K=8, main_thread)
 *
 *   ingest:            1 EVALSHA    (was: 1 pipeline + 2 conditional HGETs)
 *   buildContextBlock: 1 mGetDirect (same as precompute, but concurrent-safe)
 *   p99 under K=8:     expected ≈ precompute single-agent p99 (~4 ms)
 *                      not 58 ms, because the Kotlin mutex is gone
 */
class DazzleIncrementalIoTManager : StorageBackend {

    override val backendName: String = "Dazzle-Incremental"

    private val dazzle: Dazzle = DazzleServer.client()
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")
    private val decisions = dazzle.list("agent:decisions")

    // ── Lua ingest script ─────────────────────────────────────────────────
    // Atomically: stream-append + stats + min/max + rolling-temps + trend +
    // window-anomalies + derived-field HSET. One EVALSHA crossing per ingest.
    //
    // KEYS: [1]=sensor:readings  [2]=sensor:stats
    //       [3]=sensor:temps_recent  [4]=sensor:anomalies
    // ARGV: [1]=tempC  [2]=humidity  [3]=minute  [4]=anomalous(1/0)
    //       [5]=windowMinutes
    private val ingestScript = dazzle.script("""
        local temp    = tonumber(ARGV[1])
        local minute  = tonumber(ARGV[3])
        local win_min = tonumber(ARGV[5]) or 20

        -- 1. Stream append
        redis.call('XADD', KEYS[1], 'MAXLEN', '~', '200', '*',
            'temp', ARGV[1], 'humidity', ARGV[2],
            'minute', ARGV[3], 'anomalous', ARGV[4])

        -- 2. Running aggregates
        redis.call('HINCRBYFLOAT', KEYS[2], 'temp_sum', ARGV[1])
        redis.call('HINCRBY',      KEYS[2], 'count', 1)
        redis.call('HSET', KEYS[2], 'latest_temp', ARGV[1], 'latest_minute', ARGV[3])

        -- 3. Conditional min/max (no Kotlin read-then-write round trip)
        local cur_min = tonumber(redis.call('HGET', KEYS[2], 'min_temp'))
        if not cur_min or temp < cur_min then
            redis.call('HSET', KEYS[2], 'min_temp', ARGV[1])
        end
        local cur_max = tonumber(redis.call('HGET', KEYS[2], 'max_temp'))
        if not cur_max or temp > cur_max then
            redis.call('HSET', KEYS[2], 'max_temp', ARGV[1])
        end

        -- 4. Anomaly tracking
        if ARGV[4] == '1' then
            redis.call('ZADD', KEYS[4], minute, ARGV[3])
            redis.call('HINCRBY', KEYS[2], 'anomaly_count', 1)
        end

        -- 5. Rolling temps list (newest-first, max 10)
        redis.call('LPUSH', KEYS[3], ARGV[1])
        redis.call('LTRIM', KEYS[3], 0, 9)

        -- 6. OLS trend over last 10 temps
        local raw = redis.call('LRANGE', KEYS[3], 0, -1)
        local n   = #raw
        local slope = 0.0
        if n >= 2 then
            local sx, sy, sxy, sxx = 0.0, 0.0, 0.0, 0.0
            for i = 1, n do
                local x = n - i
                local y = tonumber(raw[i])
                sx  = sx  + x
                sy  = sy  + y
                sxy = sxy + x * y
                sxx = sxx + x * x
            end
            local denom = n * sxx - sx * sx
            if denom ~= 0 then slope = (n * sxy - sx * sy) / denom end
        end
        local trend = 'stable'
        if     slope >  0.15 then trend = 'increasing'
        elseif slope < -0.15 then trend = 'decreasing'
        end

        -- 7. Recent temps CSV (oldest→newest for display)
        local parts = {}
        for i = n, 1, -1 do
            parts[n - i + 1] = string.format('%.1f', tonumber(raw[i]))
        end
        local temps_csv = table.concat(parts, ',')

        -- 8. Window anomalies
        local win_start  = math.max(0, minute - win_min)
        local win_anoms  = redis.call('ZRANGEBYSCORE', KEYS[4], win_start, minute)
        local anoms_csv  = table.concat(win_anoms, ',')

        -- 9. Persist derived fields atomically
        redis.call('HSET', KEYS[2],
            'recent_temps_csv',    temps_csv,
            'recent_trend',        trend,
            'window_anomalies_csv', anoms_csv,
            'window_minutes',      tostring(win_min))

        return 1
    """.trimIndent())

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        stats.delete()
        anomalies.deleteKey()
        decisions.deleteKey()
        dazzle.stream("sensor:readings").deleteKey()
        dazzle.list("sensor:temps_recent").deleteKey()
        for (i in 0..9) dazzle.hash("agent:checkpoint:$i").delete()
    }

    // ── Ingest: 1 EVALSHA, no Kotlin mutex ───────────────────────────────

    override fun ingest(reading: SensorReading) {
        ingestScript.eval(
            keys = listOf(
                "sensor:readings",
                "sensor:stats",
                "sensor:temps_recent",
                "sensor:anomalies",
            ),
            args = listOf(
                reading.tempC.toString(),
                reading.humidity.toString(),
                reading.minute.toString(),
                if (reading.anomalous) "1" else "0",
                "20",
            ),
        )
    }

    // ── Context block: 1 mGetDirect, concurrent-safe ─────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val fields = stats.mGetDirect(
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count",
            "recent_temps_csv", "recent_trend", "window_anomalies_csv",
        )

        val lines = mutableListOf<String>()

        val tempsCsv = fields.getOrNull(5)
        if (!tempsCsv.isNullOrEmpty()) {
            lines += "Last ${tempsCsv.split(",").size} temperatures (oldest→newest, °C): $tempsCsv"
            lines += "Recent trend: ${fields.getOrNull(6) ?: "stable"}"
        }

        val count = fields.getOrNull(0)?.toIntOrNull()
        if (count != null && count > 0) {
            val sum     = fields.getOrNull(1)?.toDoubleOrNull() ?: 0.0
            val minT    = fields.getOrNull(2)?.toDoubleOrNull() ?: 0.0
            val maxT    = fields.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val anomCnt = fields.getOrNull(4)?.toIntOrNull()    ?: 0
            lines += "Aggregate over $count readings: " +
                "avg=${String.format("%.1f", sum / count)}°C, " +
                "min=${String.format("%.1f", minT)}°C, " +
                "max=${String.format("%.1f", maxT)}°C"
            lines += "Total anomalies detected so far: $anomCnt"
        }

        val windowAnomsCsv = fields.getOrNull(7)
        if (windowAnomsCsv.isNullOrEmpty()) {
            lines += "No anomalies in the last $windowMinutes minutes."
        } else {
            lines += "Anomalous time indices in the last $windowMinutes minutes " +
                "(minute numbers, not temperatures): [$windowAnomsCsv]"
        }

        return lines.joinToString("\n")
    }

    override fun buildSynthesisContext(): String {
        val lines = mutableListOf<String>()

        val fields = stats.mGetDirect("count", "temp_sum", "min_temp", "max_temp", "anomaly_count")
        val count = fields.getOrNull(0)?.toIntOrNull()
        if (count != null && count > 0) {
            val sum     = fields.getOrNull(1)?.toDoubleOrNull() ?: 0.0
            val minT    = fields.getOrNull(2)?.toDoubleOrNull() ?: 0.0
            val maxT    = fields.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val anomCnt = fields.getOrNull(4)?.toIntOrNull()    ?: 0
            lines += "=== Full Session Stats ==="
            lines += "Total readings: $count"
            lines += "Temperature range: ${String.format("%.1f", minT)}°C to " +
                "${String.format("%.1f", maxT)}°C " +
                "(avg ${String.format("%.1f", sum / count)}°C)"
            lines += "Total anomalies detected: $anomCnt"
        }

        val allAnomalyMins = anomalies.rangeByScore(min = 0.0, max = 99999.0)
        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
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
        index: Int, minute: Int, anomalyDetected: Boolean,
        severity: String, trend: String,
    ) {
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} " +
            "severity=$severity trend=$trend"
        DazzleServer.directPipeline(listOf(
            listOf("HSET", "agent:checkpoint:$index",
                "minute", minute.toString(),
                "anomaly", if (anomalyDetected) "1" else "0",
                "severity", severity, "trend", trend),
            listOf("RPUSH", "agent:decisions", decision),
        ))
    }

    override fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        return (System.nanoTime() - start) / 1_000.0
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
