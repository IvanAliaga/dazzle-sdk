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
import io.objectbox.BoxStore
import io.objectbox.kotlin.boxFor
import io.objectbox.query.QueryBuilder
import dev.dazzle.experiment.objectbox.*
import java.io.File

/**
 * ObjectBox-based [StorageBackend] for the Sequential Monitoring Agent.
 *
 * ObjectBox is a mobile-native object database with vector search since
 * v4.0. This implementation mirrors the exact same data layout and
 * produces byte-identical context blocks as Valkey and SQLite.
 *
 * The comparison is valuable because ObjectBox IS a real competitor in
 * the embedded mobile DB space — it's purpose-built for Android/iOS,
 * has 800k+ developers, and its vector support is a direct competitor
 * to Valkey 8's vector search module.
 *
 * What ObjectBox CAN do that SQLite can't:
 *   - Native object persistence (no ORM / SQL mapping)
 *   - Vector search (since 4.0) for semantic queries
 *   - Data observers for reactive UIs
 *
 * What ObjectBox CANNOT do that Valkey can:
 *   - Auto-trimmed streams (XADD MAXLEN)
 *   - Atomic float increment (HINCRBYFLOAT)
 *   - Per-field TTL (HFE)
 *   - Sorted set range queries by score
 *   - HyperLogLog cardinality estimation
 *   - Geo index
 *   - Pub/Sub channels
 *   - Lua scripting
 */
class ObjectBoxContextManager(context: Context) : StorageBackend {

    override val backendName: String = "ObjectBox"

    // ObjectBox is built on LMDB underneath, so it inherits the same
    // pre-allocate-and-reuse behaviour: data.mdb sticks at its high-water
    // mark and removeAll() releases pages to the freelist instead of
    // shrinking the file. Wipe the backing directory before BoxStore
    // opens so the "before" snapshot starts truly empty.
    private val dbDir = File(
        context.applicationContext.filesDir, "objectbox/sensor-experiment-objectbox"
    ).also { if (it.exists()) it.deleteRecursively() }

    private val store: BoxStore = MyObjectBox.builder()
        .androidContext(context.applicationContext)
        .name("sensor-experiment-objectbox")
        .build()

    private val readingsBox   = store.boxFor<ReadingEntity>()
    private val statsBox      = store.boxFor<StatsEntity>()
    private val anomaliesBox  = store.boxFor<AnomalyEntity>()
    private val decisionsBox  = store.boxFor<DecisionEntity>()
    private val checkpointsBox = store.boxFor<CheckpointEntity>()

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        readingsBox.removeAll()
        statsBox.removeAll()
        anomaliesBox.removeAll()
        decisionsBox.removeAll()
        checkpointsBox.removeAll()
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        readingsBox.put(ReadingEntity(
            minute    = reading.minute,
            temp      = reading.tempC,
            humidity  = reading.humidity,
            anomalous = reading.anomalous,
        ))

        // Trim to ~200 entries
        val count = readingsBox.count()
        if (count > 210) {
            val toRemove = readingsBox.query()
                .order(ReadingEntity_.id)
                .build()
                .find(0, (count - 200))
            readingsBox.remove(toRemove)
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
            val existing = anomaliesBox.query()
                .equal(AnomalyEntity_.minute, reading.minute.toLong())
                .build()
                .findFirst()
            if (existing == null) {
                anomaliesBox.put(AnomalyEntity(minute = reading.minute))
            }
            upsertStat("anomaly_count", 1.0, increment = true)
        }
    }

    // ── Context block ─────────────────────────────────────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        val recent = readingsBox.query()
            .order(ReadingEntity_.id, QueryBuilder.DESCENDING)
            .build()
            .find(0, 10)
            .reversed()
        val recentTemps = recent.map { it.temp }

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
        val windowAnomalies = anomaliesBox.query()
            .between(AnomalyEntity_.minute, windowStart.toLong(), currentMinute.toLong())
            .order(AnomalyEntity_.minute)
            .build()
            .find()
            .map { it.minute }

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

        val allAnomalyMins = anomaliesBox.query()
            .order(AnomalyEntity_.minute)
            .build()
            .find()
            .map { it.minute }

        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
        }

        val decisionEntities = decisionsBox.query()
            .order(DecisionEntity_.cpIndex)
            .build()
            .find()

        if (decisionEntities.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            for (d in decisionEntities) {
                lines += "  Checkpoint ${d.cpIndex + 1}: ${d.decision}"
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

        val existingCp = checkpointsBox.query()
            .equal(CheckpointEntity_.cpIndex, index.toLong())
            .build()
            .findFirst()
        checkpointsBox.put(CheckpointEntity(
            id       = existingCp?.id ?: 0,
            cpIndex  = index,
            minute   = minute,
            anomaly  = anomalyDetected,
            severity = severity,
            trend    = trend,
        ))

        val existingD = decisionsBox.query()
            .equal(DecisionEntity_.cpIndex, index.toLong())
            .build()
            .findFirst()
        decisionsBox.put(DecisionEntity(
            id       = existingD?.id ?: 0,
            cpIndex  = index,
            decision = decision,
        ))
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

    private fun getStat(key: String): Double? {
        return statsBox.query()
            .equal(StatsEntity_.key, key, io.objectbox.query.QueryBuilder.StringOrder.CASE_SENSITIVE)
            .build()
            .findFirst()
            ?.value
    }

    private fun upsertStat(key: String, value: Double, increment: Boolean) {
        val existing = statsBox.query()
            .equal(StatsEntity_.key, key, io.objectbox.query.QueryBuilder.StringOrder.CASE_SENSITIVE)
            .build()
            .findFirst()
        if (existing == null) {
            statsBox.put(StatsEntity(key = key, value = value))
        } else {
            existing.value = if (increment) existing.value + value else value
            statsBox.put(existing)
        }
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

    override val backendSizeMethod: String = "objectbox:dir_st_blocks"

    /**
     * Sum on-disk usage across the ObjectBox directory using
     * `st_blocks * 512` (matches `du -k`). `BoxStore.dbSizeOnDisk`
     * reports the apparent file length of `data.mdb`, which stays at
     * the LMDB pre-allocation high-water mark; it doesn't reflect
     * sparse-region reality. The block-based measurement is the same
     * one we use for LMDB and is the honest disk footprint.
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
