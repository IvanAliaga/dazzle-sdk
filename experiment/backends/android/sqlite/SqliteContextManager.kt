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

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/**
 * SQLite-based [StorageBackend] for the Sequential Monitoring Agent experiment.
 *
 * This is the apples-to-apples comparison against [ValkeyContextManager]. It
 * stores the exact same data (readings, running aggregates, anomaly indices,
 * agent checkpoint decisions) and produces the **exact same context blocks**
 * (byte-for-byte identical strings) so the Gemma model sees an identical
 * prompt regardless of which backend is active.
 *
 * Design choices that mirror the Valkey implementation:
 *   - Readings are trimmed to the last 200 rows (equivalent to MAXLEN ~200)
 *   - Running stats are maintained incrementally (no COUNT(*)/AVG(*) on read)
 *   - Anomaly minutes are stored in a dedicated table with indexed minute column
 *   - Agent decisions are appended in order (equivalent to RPUSH)
 *
 * What SQLite CANNOT express as a single primitive that Valkey can:
 *   - Auto-trimmed stream → requires a DELETE trigger or post-INSERT trim
 *   - Atomic float increment → requires BEGIN/UPDATE SET x=x+?/COMMIT
 *   - Per-field TTL (HFE) → requires expiration column + periodic purge
 *   - Sorted range query with score → requires explicit B-tree index
 *   - HyperLogLog / Bitmap / Geo → not available
 */
class SqliteContextManager(context: Context) : StorageBackend {

    override val backendName: String = "SQLite"

    private val db: SQLiteDatabase

    init {
        val helper = object : SQLiteOpenHelper(context, "sensor_experiment.db", null, 1) {
            override fun onCreate(db: SQLiteDatabase) {
                db.execSQL("""
                    CREATE TABLE readings (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        minute INTEGER NOT NULL,
                        temp REAL NOT NULL,
                        humidity REAL NOT NULL,
                        anomalous INTEGER NOT NULL DEFAULT 0
                    )
                """)
                db.execSQL("CREATE INDEX idx_readings_minute ON readings(minute)")

                db.execSQL("""
                    CREATE TABLE stats (
                        key TEXT PRIMARY KEY,
                        value REAL NOT NULL DEFAULT 0
                    )
                """)

                db.execSQL("""
                    CREATE TABLE anomalies (
                        minute INTEGER PRIMARY KEY
                    )
                """)

                db.execSQL("""
                    CREATE TABLE decisions (
                        cp_index INTEGER PRIMARY KEY,
                        decision TEXT NOT NULL
                    )
                """)

                db.execSQL("""
                    CREATE TABLE checkpoints (
                        cp_index INTEGER PRIMARY KEY,
                        minute INTEGER NOT NULL,
                        anomaly INTEGER NOT NULL,
                        severity TEXT NOT NULL,
                        trend TEXT NOT NULL
                    )
                """)
            }

            override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {
                db.execSQL("DROP TABLE IF EXISTS readings")
                db.execSQL("DROP TABLE IF EXISTS stats")
                db.execSQL("DROP TABLE IF EXISTS anomalies")
                db.execSQL("DROP TABLE IF EXISTS decisions")
                db.execSQL("DROP TABLE IF EXISTS checkpoints")
                onCreate(db)
            }
        }
        db = helper.writableDatabase
        // WAL mode for better concurrent read/write performance.
        // PRAGMA returns a result row, so we must use rawQuery not execSQL.
        db.rawQuery("PRAGMA journal_mode=WAL", null).use { it.moveToFirst() }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        db.execSQL("DELETE FROM readings")
        db.execSQL("DELETE FROM stats")
        db.execSQL("DELETE FROM anomalies")
        db.execSQL("DELETE FROM decisions")
        db.execSQL("DELETE FROM checkpoints")
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        // Insert reading
        val cv = ContentValues().apply {
            put("minute", reading.minute)
            put("temp", reading.tempC)
            put("humidity", reading.humidity)
            put("anomalous", if (reading.anomalous) 1 else 0)
        }
        db.insert("readings", null, cv)

        // Trim to last 200 readings (equivalent to Valkey MAXLEN ~200).
        // Android's execSQL rejects DELETE with embedded SELECT subqueries,
        // so we query the cutoff id first and delete in a separate step.
        val rowCount = android.database.DatabaseUtils.queryNumEntries(db, "readings")
        if (rowCount > 210) {  // small buffer to avoid trimming on every insert
            db.rawQuery(
                "SELECT id FROM readings ORDER BY id DESC LIMIT 1 OFFSET 200",
                null
            ).use { c ->
                if (c.moveToFirst()) {
                    val cutoffId = c.getLong(0)
                    db.execSQL("DELETE FROM readings WHERE id <= ?", arrayOf(cutoffId))
                }
            }
        }

        // Update running stats incrementally
        upsertStat("temp_sum", reading.tempC, increment = true)
        upsertStat("count", 1.0, increment = true)
        upsertStat("latest_temp", reading.tempC, increment = false)
        upsertStat("latest_minute", reading.minute.toDouble(), increment = false)

        // Min / max
        val curMin = getStat("min_temp")
        if (curMin == null || reading.tempC < curMin) {
            upsertStat("min_temp", reading.tempC, increment = false)
        }
        val curMax = getStat("max_temp")
        if (curMax == null || reading.tempC > curMax) {
            upsertStat("max_temp", reading.tempC, increment = false)
        }

        // Anomaly tracking
        if (reading.anomalous) {
            val acv = ContentValues().apply { put("minute", reading.minute) }
            db.insertWithOnConflict("anomalies", null, acv, SQLiteDatabase.CONFLICT_IGNORE)
            upsertStat("anomaly_count", 1.0, increment = true)
        }
    }

    // ── Context block (byte-identical to Valkey output) ───────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        // Last 10 readings (oldest → newest)
        val recentTemps = mutableListOf<Double>()
        db.rawQuery(
            "SELECT temp FROM readings ORDER BY id DESC LIMIT 10",
            null
        ).use { c ->
            while (c.moveToNext()) recentTemps.add(0, c.getDouble(0))
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
        val windowAnomalies = mutableListOf<Int>()
        db.rawQuery(
            "SELECT minute FROM anomalies WHERE minute BETWEEN ? AND ? ORDER BY minute",
            arrayOf(windowStart.toString(), currentMinute.toString())
        ).use { c ->
            while (c.moveToNext()) windowAnomalies += c.getInt(0)
        }

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

        // All anomaly minutes
        val allAnomalyMins = mutableListOf<Int>()
        db.rawQuery("SELECT minute FROM anomalies ORDER BY minute", null).use { c ->
            while (c.moveToNext()) allAnomalyMins += c.getInt(0)
        }
        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
        }

        // Per-checkpoint decisions
        val decisionLines = mutableListOf<Pair<Int, String>>()
        db.rawQuery("SELECT cp_index, decision FROM decisions ORDER BY cp_index", null).use { c ->
            while (c.moveToNext()) decisionLines += c.getInt(0) to c.getString(1)
        }
        if (decisionLines.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            for ((idx, decision) in decisionLines) {
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

        val cpCv = ContentValues().apply {
            put("cp_index", index)
            put("minute", minute)
            put("anomaly", if (anomalyDetected) 1 else 0)
            put("severity", severity)
            put("trend", trend)
        }
        db.insertWithOnConflict("checkpoints", null, cpCv, SQLiteDatabase.CONFLICT_REPLACE)

        val dCv = ContentValues().apply {
            put("cp_index", index)
            put("decision", decision)
        }
        db.insertWithOnConflict("decisions", null, dCv, SQLiteDatabase.CONFLICT_REPLACE)
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
        val sum      = getStat("temp_sum") ?: 0.0
        val minTemp  = getStat("min_temp") ?: 0.0
        val maxTemp  = getStat("max_temp") ?: 0.0
        val anomCnt  = getStat("anomaly_count")?.toInt() ?: 0
        return RunningStats(
            count        = count,
            avgTemp      = sum / count,
            minTemp      = minTemp,
            maxTemp      = maxTemp,
            anomalyCount = anomCnt,
        )
    }

    private fun getStat(key: String): Double? {
        db.rawQuery("SELECT value FROM stats WHERE key = ?", arrayOf(key)).use { c ->
            return if (c.moveToFirst()) c.getDouble(0) else null
        }
    }

    private fun upsertStat(key: String, value: Double, increment: Boolean) {
        val existing = getStat(key)
        if (existing == null) {
            val cv = ContentValues().apply {
                put("key", key)
                put("value", value)
            }
            db.insertWithOnConflict("stats", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
        } else {
            val newVal = if (increment) existing + value else value
            val cv = ContentValues().apply { put("value", newVal) }
            db.update("stats", cv, "key = ?", arrayOf(key))
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

    override val backendSizeMethod: String = "sqlite:db_file_size"

    /**
     * Sum of the SQLite database file plus its WAL/SHM siblings. Reading
     * `pragma page_count * page_size` would skip the WAL log; for the
     * paper we want the on-disk footprint a user would actually see in
     * `du`, including the journal Android creates in WAL mode.
     */
    override fun backendSizeBytes(): Long {
        val mainPath = db.path ?: return -1L
        val main = File(mainPath)
        val wal  = File(mainPath + "-wal")
        val shm  = File(mainPath + "-shm")
        val journal = File(mainPath + "-journal")
        var total = 0L
        if (main.exists())    total += main.length()
        if (wal.exists())     total += wal.length()
        if (shm.exists())     total += shm.length()
        if (journal.exists()) total += journal.length()
        return total
    }
}
