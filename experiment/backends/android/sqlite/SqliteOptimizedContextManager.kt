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
 * SQLite backend with write-time materialized aggregates maintained by triggers.
 *
 * This variant exists to benchmark SQLite under the same architectural pattern
 * as Dazzle-Precompute: aggregate state is materialized on write and retrieval
 * reads O(1) scalar fields.
 */
class SqliteOptimizedContextManager(context: Context) : StorageBackend {

    override val backendName: String = "SQLite-Optimized"

    private val db: SQLiteDatabase

    init {
        val helper = object : SQLiteOpenHelper(context, "sensor_experiment_opt.db", null, 1) {
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
                db.execSQL("CREATE INDEX idx_readings_minute_opt ON readings(minute)")

                db.execSQL("""
                    CREATE TABLE agg_state (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        count INTEGER NOT NULL DEFAULT 0,
                        temp_sum REAL NOT NULL DEFAULT 0,
                        min_temp REAL NOT NULL DEFAULT 0,
                        max_temp REAL NOT NULL DEFAULT 0,
                        anomaly_count INTEGER NOT NULL DEFAULT 0,
                        latest_temp REAL NOT NULL DEFAULT 0,
                        latest_minute INTEGER NOT NULL DEFAULT 0
                    )
                """)
                db.execSQL("INSERT OR IGNORE INTO agg_state (id) VALUES (1)")

                db.execSQL("""
                    CREATE TRIGGER readings_after_insert_agg
                    AFTER INSERT ON readings
                    BEGIN
                        INSERT OR IGNORE INTO agg_state (id) VALUES (1);
                        UPDATE agg_state
                        SET
                            count = count + 1,
                            temp_sum = temp_sum + NEW.temp,
                            min_temp = CASE
                                WHEN count = 0 OR NEW.temp < min_temp THEN NEW.temp
                                ELSE min_temp
                            END,
                            max_temp = CASE
                                WHEN count = 0 OR NEW.temp > max_temp THEN NEW.temp
                                ELSE max_temp
                            END,
                            anomaly_count = anomaly_count + CASE
                                WHEN NEW.anomalous = 1 THEN 1 ELSE 0
                            END,
                            latest_temp = NEW.temp,
                            latest_minute = NEW.minute
                        WHERE id = 1;
                    END
                """)

                db.execSQL("CREATE TABLE anomalies (minute INTEGER PRIMARY KEY)")

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
                db.execSQL("DROP TABLE IF EXISTS agg_state")
                db.execSQL("DROP TABLE IF EXISTS anomalies")
                db.execSQL("DROP TABLE IF EXISTS decisions")
                db.execSQL("DROP TABLE IF EXISTS checkpoints")
                db.execSQL("DROP TRIGGER IF EXISTS readings_after_insert_agg")
                onCreate(db)
            }
        }
        db = helper.writableDatabase
        db.rawQuery("PRAGMA journal_mode=WAL", null).use { it.moveToFirst() }
    }

    override fun flush() {
        db.execSQL("DELETE FROM readings")
        db.execSQL("DELETE FROM anomalies")
        db.execSQL("DELETE FROM decisions")
        db.execSQL("DELETE FROM checkpoints")
        db.execSQL("DELETE FROM agg_state")
        db.execSQL("INSERT OR IGNORE INTO agg_state (id) VALUES (1)")
    }

    override fun ingest(reading: SensorReading) {
        val cv = ContentValues().apply {
            put("minute", reading.minute)
            put("temp", reading.tempC)
            put("humidity", reading.humidity)
            put("anomalous", if (reading.anomalous) 1 else 0)
        }
        db.insert("readings", null, cv)

        val rowCount = android.database.DatabaseUtils.queryNumEntries(db, "readings")
        if (rowCount > 210) {
            db.rawQuery(
                "SELECT id FROM readings ORDER BY id DESC LIMIT 1 OFFSET 200",
                null,
            ).use { c ->
                if (c.moveToFirst()) {
                    val cutoffId = c.getLong(0)
                    db.execSQL("DELETE FROM readings WHERE id <= ?", arrayOf(cutoffId))
                }
            }
        }

        if (reading.anomalous) {
            val acv = ContentValues().apply { put("minute", reading.minute) }
            db.insertWithOnConflict("anomalies", null, acv, SQLiteDatabase.CONFLICT_IGNORE)
        }
    }

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        val recentTemps = mutableListOf<Double>()
        db.rawQuery(
            "SELECT temp FROM readings ORDER BY id DESC LIMIT 10",
            null,
        ).use { c ->
            while (c.moveToNext()) recentTemps.add(0, c.getDouble(0))
        }
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
        val windowAnomalies = mutableListOf<Int>()
        db.rawQuery(
            "SELECT minute FROM anomalies WHERE minute BETWEEN ? AND ? ORDER BY minute",
            arrayOf(windowStart.toString(), currentMinute.toString()),
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

        val allAnomalyMins = mutableListOf<Int>()
        db.rawQuery("SELECT minute FROM anomalies ORDER BY minute", null).use { c ->
            while (c.moveToNext()) allAnomalyMins += c.getInt(0)
        }
        if (allAnomalyMins.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalyMins.joinToString(", ")}]"
        }

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

    private data class RunningStats(
        val count: Int,
        val avgTemp: Double,
        val minTemp: Double,
        val maxTemp: Double,
        val anomalyCount: Int,
    )

    private fun readStats(): RunningStats? {
        var out: RunningStats? = null
        db.rawQuery(
            "SELECT count, temp_sum, min_temp, max_temp, anomaly_count FROM agg_state WHERE id = 1",
            null,
        ).use { c ->
            if (!c.moveToFirst()) return null
            val count = c.getInt(0)
            if (count <= 0) return null
            val sum = c.getDouble(1)
            val minTemp = c.getDouble(2)
            val maxTemp = c.getDouble(3)
            val anomalyCount = c.getInt(4)
            out = RunningStats(
                count = count,
                avgTemp = sum / count,
                minTemp = minTemp,
                maxTemp = maxTemp,
                anomalyCount = anomalyCount,
            )
        }
        return out
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

    override val backendSizeMethod: String = "sqlite:db_file_size"

    override fun backendSizeBytes(): Long {
        val mainPath = db.path ?: return -1L
        val main = File(mainPath)
        val wal = File(mainPath + "-wal")
        val shm = File(mainPath + "-shm")
        val journal = File(mainPath + "-journal")
        var total = 0L
        if (main.exists()) total += main.length()
        if (wal.exists()) total += wal.length()
        if (shm.exists()) total += shm.length()
        if (journal.exists()) total += journal.length()
        return total
    }
}
