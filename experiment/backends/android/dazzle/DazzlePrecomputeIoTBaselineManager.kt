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

/**
 * Precompute backend v2 — the materialised-view approach taken to its
 * logical conclusion.
 *
 * ## Why v2 exists
 *
 * The v1 precompute stored derived fields in a Valkey hash but kept a
 * rolling-temperature ArrayDeque in Kotlin user-space and did min/max
 * read-then-write from Kotlin. Under K≥2 concurrent agents that shared
 * state forced `@Synchronized` on `ingest()`, which serialised every
 * concurrent write. Measured on a Moto g35 at K=8: p99 = 54 ms under
 * parallel reads — 4.7× worse than dazzle-basic, which has no such
 * mutex.
 *
 * v2 eliminates the Kotlin monitor entirely by moving all mutable state
 * into Valkey and running the whole ingest pipeline as a single EVALSHA.
 *
 * ## What makes this "precompute" (and not "incremental")
 *
 * `DazzleIncrementalIoTManager` materialises the individual derived
 * fields (temps_csv, trend, window_anomalies_csv) and rebuilds the
 * context-block string in Kotlin on every read via an `mGetDirect` of
 * 8 fields plus 5+ `String.format` calls.
 *
 * This backend goes one step further: the Lua script assembles the
 * **entire pre-rendered `ctx_block` string** atomically. Retrieval is
 * therefore a single-field `mGetDirect("ctx_block")` plus two trivial
 * `replace` calls to restore the two Unicode glyphs (`°`, `→`) that
 * can't round-trip through the SDK's UTF-8-to-UTF-16 transport path
 * (the RESP parser indexes bulks by character count, not byte count —
 * so ASCII-only storage is required when we fall back to the pipe).
 *
 *   incremental:   mGetDirect(8 fields) + Kotlin String.format × 5+
 *   precompute v2: mGetDirect(1 field)  + 2 ASCII→Unicode replace passes
 *
 * ## Snapshot fast-path
 *
 * Commands dispatched by Kotlin's direct path mirror their writes into
 * the in-process snapshot cache; commands executed **inside a Lua
 * script** do not. To keep the TYPED snapshot read hot (≈50 µs instead
 * of the pipe HMGET's ≈2 ms), v2 has Lua **return** the pre-rendered
 * ASCII block and then Kotlin does one direct-path `HSET ctx_block`,
 * which does fire the mirror. That adds one extra round-trip per
 * ingest, but eliminates the pipe path from every subsequent read —
 * a net win under the read-heavy 80/20 multi-agent workload.
 */
class DazzlePrecomputeIoTBaselineManager : StorageBackend {

    override val backendName: String = "Dazzle-Precompute"

    private val dazzle: Dazzle = DazzleServer.client()
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")
    private val decisions = dazzle.list("agent:decisions")

    // ── Lua ingest script ─────────────────────────────────────────────────
    // Atomically: stream append + running aggregates + server-side min/max +
    // rolling-temps list + OLS trend + window-anomalies + pre-rendered
    // ctx_block string. Returns the block as an ASCII bulk so Kotlin can
    // re-HSET it via the direct path and populate the snapshot cache.
    //
    // Unicode glyphs are kept out of the stored/returned string via the
    // tokens ~DEG~ (for °) and ~ARR~ (for →); Kotlin substitutes them on
    // read. This side-steps the RESP parser's byte-vs-character mismatch
    // on multi-byte payloads that flow through the pipe fallback path.
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

        -- 2. Running aggregates — capture post-increment values
        local new_count = redis.call('HINCRBY', KEYS[2], 'count', 1)
        local new_sum   = tonumber(redis.call('HINCRBYFLOAT', KEYS[2], 'temp_sum', ARGV[1]))
        redis.call('HSET', KEYS[2], 'latest_temp', ARGV[1], 'latest_minute', ARGV[3])

        -- 3. Conditional min/max — entirely server-side, track current values
        local cur_min = tonumber(redis.call('HGET', KEYS[2], 'min_temp'))
        if not cur_min or temp < cur_min then
            cur_min = temp
            redis.call('HSET', KEYS[2], 'min_temp', ARGV[1])
        end
        local cur_max = tonumber(redis.call('HGET', KEYS[2], 'max_temp'))
        if not cur_max or temp > cur_max then
            cur_max = temp
            redis.call('HSET', KEYS[2], 'max_temp', ARGV[1])
        end

        -- 4. Anomaly tracking
        local anom_cnt = tonumber(redis.call('HGET', KEYS[2], 'anomaly_count')) or 0
        if ARGV[4] == '1' then
            redis.call('ZADD', KEYS[4], minute, ARGV[3])
            anom_cnt = redis.call('HINCRBY', KEYS[2], 'anomaly_count', 1)
        end

        -- 5. Rolling temps list (newest-first, max 10)
        redis.call('LPUSH', KEYS[3], ARGV[1])
        redis.call('LTRIM', KEYS[3], 0, 9)
        local raw = redis.call('LRANGE', KEYS[3], 0, -1)
        local n   = #raw

        -- 6. OLS slope over the rolling window
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

        -- 8. Window anomalies (baked for reading.minute's window)
        local win_start = math.max(0, minute - win_min)
        local win_anoms = redis.call('ZRANGEBYSCORE', KEYS[4], win_start, minute)
        local anoms_csv = table.concat(win_anoms, ',')

        -- 9. Build the FULL pre-rendered ctx_block with ASCII-only tokens
        local lines = {}
        if temps_csv ~= '' then
            lines[#lines+1] = 'Last ' .. n .. ' temperatures (oldest~ARR~newest, ~DEG~C): ' .. temps_csv
            lines[#lines+1] = 'Recent trend: ' .. trend
        end
        if new_count and new_count > 0 then
            local avg = new_sum / new_count
            lines[#lines+1] = 'Aggregate over ' .. new_count .. ' readings: ' ..
                'avg=' .. string.format('%.1f', avg) .. '~DEG~C, ' ..
                'min=' .. string.format('%.1f', cur_min) .. '~DEG~C, ' ..
                'max=' .. string.format('%.1f', cur_max) .. '~DEG~C'
            lines[#lines+1] = 'Total anomalies detected so far: ' .. anom_cnt
        end
        if anoms_csv == '' then
            lines[#lines+1] = 'No anomalies in the last ' .. win_min .. ' minutes.'
        else
            lines[#lines+1] = 'Anomalous time indices in the last ' .. win_min .. ' minutes ' ..
                '(minute numbers, not temperatures): [' .. anoms_csv .. ']'
        end

        -- 10. HSET ctx_block inside the Lua script so we avoid a second
        --     JNI crossing + pipe round-trip from Kotlin. Post-EVAL auto-
        --     mirror (plan 10) iterates sensor:stats hash and hydrates
        --     ctx_block into the snapshot, so subsequent getDirect calls
        --     still hit the fast path.
        local ctx = table.concat(lines, '\n')
        redis.call('HSET', KEYS[2], 'ctx_block', ctx)
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

    // ── Ingest: 1 EVALSHA + 1 direct HSET (no Kotlin mutex) ──────────────

    override fun ingest(reading: SensorReading) {
        // Lua HSETs ctx_block internally; post-EVAL auto-mirror (plan 10)
        // hydrates it into the snapshot cache. Net: one JNI crossing +
        // one event-loop round-trip per ingest (was two).
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

    // ── Context block: 1 snapshot read + 2 ASCII→Unicode replaces ────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val ascii = stats.getDirect("ctx_block") ?: return ""
        return ascii.replace("~ARR~", "→").replace("~DEG~", "°")
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
                "severity", severity,
                "trend", trend),
            listOf("RPUSH", "agent:decisions", decision),
        ))
    }

    override fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        return (System.nanoTime() - start) / 1_000.0
    }
}
