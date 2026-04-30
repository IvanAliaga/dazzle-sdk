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

import Foundation
import SQLite3

/// SQLite backend with write-time pre-rendered context block.
///
/// `sqlite-optimized` already materializes scalar aggregates via
/// trigger. This variant goes one step further and also stores a
/// pre-rendered context block (`ctx_block`) on ingest, so retrieval
/// is a single-row read against the `context_cache` table — the
/// SQLite analogue of Dazzle-Precompute's snapshot field copy.
///
/// Mirrors `experiment/backends/android/sqlite/
/// SqlitePrecomputeContextManager.kt` byte-for-byte on the SQL surface
/// so Android↔iOS comparisons are apples-to-apples.
final class SqlitePrecomputeContextManager: StorageBackend {

    let backendName: String = "SQLite-Precompute"

    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("sensor_experiment_precompute.db").path
        self.dbPath = path

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("[SQLite-Precompute] Failed to open database at \(path)")
            return
        }

        exec("PRAGMA journal_mode=WAL")

        exec("""
            CREATE TABLE IF NOT EXISTS readings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                minute INTEGER NOT NULL,
                temp REAL NOT NULL,
                humidity REAL NOT NULL,
                anomalous INTEGER NOT NULL DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_readings_minute_pre ON readings(minute)")

        exec("""
            CREATE TABLE IF NOT EXISTS agg_state (
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
        exec("INSERT OR IGNORE INTO agg_state (id) VALUES (1)")

        exec("""
            CREATE TRIGGER IF NOT EXISTS readings_after_insert_agg_pre
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

        exec("CREATE TABLE IF NOT EXISTS anomalies (minute INTEGER PRIMARY KEY)")

        exec("""
            CREATE TABLE IF NOT EXISTS context_cache (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                minute INTEGER NOT NULL DEFAULT 0,
                ctx_block TEXT NOT NULL DEFAULT ''
            )
        """)
        exec("INSERT OR IGNORE INTO context_cache (id) VALUES (1)")

        exec("""
            CREATE TABLE IF NOT EXISTS decisions (
                cp_index INTEGER PRIMARY KEY,
                decision TEXT NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS checkpoints (
                cp_index INTEGER PRIMARY KEY,
                minute INTEGER NOT NULL,
                anomaly INTEGER NOT NULL,
                severity TEXT NOT NULL,
                trend TEXT NOT NULL
            )
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Lifecycle

    func flush() {
        exec("DELETE FROM readings")
        exec("DELETE FROM anomalies")
        exec("DELETE FROM context_cache")
        exec("DELETE FROM decisions")
        exec("DELETE FROM checkpoints")
        exec("DELETE FROM agg_state")
        exec("INSERT OR IGNORE INTO agg_state (id) VALUES (1)")
        exec("INSERT OR IGNORE INTO context_cache (id) VALUES (1)")
    }

    // MARK: - Ingest

    func ingest(_ reading: SensorReading) {
        exec("INSERT INTO readings (minute, temp, humidity, anomalous) VALUES (?, ?, ?, ?)",
             bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(reading.minute))
            sqlite3_bind_double(stmt, 2, reading.tempC)
            sqlite3_bind_double(stmt, 3, reading.humidity)
            sqlite3_bind_int(stmt, 4, reading.anomalous ? 1 : 0)
        })

        let rowCount = queryInt("SELECT COUNT(*) FROM readings") ?? 0
        if rowCount > 210 {
            if let cutoffId = queryInt64("SELECT id FROM readings ORDER BY id DESC LIMIT 1 OFFSET 200") {
                exec("DELETE FROM readings WHERE id <= ?", bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, cutoffId)
                })
            }
        }

        if reading.anomalous {
            exec("INSERT OR IGNORE INTO anomalies (minute) VALUES (?)", bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(reading.minute))
            })
        }

        // The Precompute distinction: rebuild and persist the context
        // block on every ingest, so retrieval is a single-row read.
        refreshContextCache(currentMinute: reading.minute, windowMinutes: 20)
    }

    // MARK: - Context block

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        // Hot path: read pre-rendered block from context_cache.
        var cached: String?
        query("SELECT ctx_block FROM context_cache WHERE id = 1") { stmt in
            if let cstr = sqlite3_column_text(stmt, 0) {
                cached = String(cString: cstr)
            }
        }
        if let cached = cached, !cached.isEmpty {
            return cached
        }
        // Cold path (cache empty after flush): recompute on demand.
        return computeContextBlockFor(currentMinute: currentMinute,
                                      windowMinutes: windowMinutes)
    }

    func buildSynthesisContext() -> String {
        var lines: [String] = []

        if let s = readStats() {
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(s.count)")
            lines.append("Temperature range: \(String(format: "%.1f", s.minTemp))\u{00B0}C to " +
                "\(String(format: "%.1f", s.maxTemp))\u{00B0}C " +
                "(avg \(String(format: "%.1f", s.avgTemp))\u{00B0}C)")
            lines.append("Total anomalies detected: \(s.anomalyCount)")
        }

        var allAnomalyMins: [Int] = []
        query("SELECT minute FROM anomalies ORDER BY minute") { stmt in
            allAnomalyMins.append(Int(sqlite3_column_int(stmt, 0)))
        }
        if !allAnomalyMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                "[\(allAnomalyMins.map(String.init).joined(separator: ", "))]")
        }

        var decisionLines: [(Int, String)] = []
        query("SELECT cp_index, decision FROM decisions ORDER BY cp_index") { stmt in
            let idx = Int(sqlite3_column_int(stmt, 0))
            let dec = String(cString: sqlite3_column_text(stmt, 1))
            decisionLines.append((idx, dec))
        }
        if !decisionLines.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (idx, decision) in decisionLines {
                lines.append("  Checkpoint \(idx + 1): \(decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Decision storage

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"

        exec("INSERT OR REPLACE INTO checkpoints (cp_index, minute, anomaly, severity, trend) VALUES (?, ?, ?, ?, ?)",
             bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(index))
            sqlite3_bind_int(stmt, 2, Int32(minute))
            sqlite3_bind_int(stmt, 3, anomalyDetected ? 1 : 0)
            sqlite3_bind_text(stmt, 4, (severity as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (trend as NSString).utf8String, -1, nil)
        })

        exec("INSERT OR REPLACE INTO decisions (cp_index, decision) VALUES (?, ?)",
             bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(index))
            sqlite3_bind_text(stmt, 2, (decision as NSString).utf8String, -1, nil)
        })
    }

    // MARK: - Private helpers

    private struct RunningStats {
        let count: Int
        let avgTemp: Double
        let minTemp: Double
        let maxTemp: Double
        let anomalyCount: Int
    }

    private func readStats() -> RunningStats? {
        var out: RunningStats?
        query("SELECT count, temp_sum, min_temp, max_temp, anomaly_count FROM agg_state WHERE id = 1") { stmt in
            let count = Int(sqlite3_column_int(stmt, 0))
            if count <= 0 { return }
            let sum = sqlite3_column_double(stmt, 1)
            let minTemp = sqlite3_column_double(stmt, 2)
            let maxTemp = sqlite3_column_double(stmt, 3)
            let anomalyCount = Int(sqlite3_column_int(stmt, 4))
            out = RunningStats(
                count: count,
                avgTemp: sum / Double(count),
                minTemp: minTemp,
                maxTemp: maxTemp,
                anomalyCount: anomalyCount
            )
        }
        return out
    }

    private func refreshContextCache(currentMinute: Int, windowMinutes: Int) {
        let ctx = computeContextBlockFor(currentMinute: currentMinute,
                                         windowMinutes: windowMinutes)
        exec("""
            INSERT INTO context_cache (id, minute, ctx_block)
            VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                minute = excluded.minute,
                ctx_block = excluded.ctx_block
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(currentMinute))
            sqlite3_bind_text(stmt, 2, (ctx as NSString).utf8String, -1, nil)
        })
    }

    private func computeContextBlockFor(currentMinute: Int, windowMinutes: Int) -> String {
        var lines: [String] = []

        var recentTemps: [Double] = []
        query("SELECT temp FROM readings ORDER BY id DESC LIMIT 10") { stmt in
            recentTemps.insert(sqlite3_column_double(stmt, 0), at: 0)
        }
        if !recentTemps.isEmpty {
            let formatted = recentTemps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            lines.append("Last \(recentTemps.count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(formatted)")
            lines.append("Recent trend: \(computeTrend(recentTemps))")
        }

        if let s = readStats() {
            lines.append("Aggregate over \(s.count) readings: " +
                "avg=\(String(format: "%.1f", s.avgTemp))\u{00B0}C, " +
                "min=\(String(format: "%.1f", s.minTemp))\u{00B0}C, " +
                "max=\(String(format: "%.1f", s.maxTemp))\u{00B0}C")
            lines.append("Total anomalies detected so far: \(s.anomalyCount)")
        }

        let windowStart = max(0, currentMinute - windowMinutes)
        var windowAnomalies: [Int] = []
        query("SELECT minute FROM anomalies WHERE minute BETWEEN ? AND ? ORDER BY minute",
              bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(windowStart))
            sqlite3_bind_int(stmt, 2, Int32(currentMinute))
        }) { stmt in
            windowAnomalies.append(Int(sqlite3_column_int(stmt, 0)))
        }

        if windowAnomalies.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(windowAnomalies.map(String.init).joined(separator: ", "))]")
        }

        return lines.joined(separator: "\n")
    }

    private func computeTrend(_ temps: [Double]) -> String {
        guard temps.count >= 2 else { return "stable" }
        let n = temps.count
        let meanX = Double(n - 1) / 2.0
        let meanY = temps.reduce(0, +) / Double(n)
        let num = (0..<n).reduce(0.0) { $0 + (Double($1) - meanX) * (temps[$1] - meanY) }
        let den = (0..<n).reduce(0.0) { $0 + pow(Double($1) - meanX, 2) }
        guard den != 0 else { return "stable" }
        let slope = num / den
        if slope > 0.15 { return "increasing" }
        if slope < -0.15 { return "decreasing" }
        return "stable"
    }

    // MARK: - SQLite C API wrappers

    @discardableResult
    private func exec(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[SQLite-Precompute] prepare failed: \(String(cString: sqlite3_errmsg(db!)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt!)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            print("[SQLite-Precompute] step failed (\(rc)): \(String(cString: sqlite3_errmsg(db!)))")
            return false
        }
        return true
    }

    private func query(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[SQLite-Precompute] prepare failed: \(String(cString: sqlite3_errmsg(db!)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt!)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt!)
        }
    }

    private func queryInt(_ sql: String) -> Int? {
        var result: Int?
        query(sql) { stmt in
            result = Int(sqlite3_column_int(stmt, 0))
        }
        return result
    }

    private func queryInt64(_ sql: String) -> Int64? {
        var result: Int64?
        query(sql) { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    // MARK: - Footprint accounting

    var backendSizeMethod: String { "sqlite:db_file_size" }

    func backendSizeBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let candidates = [dbPath, dbPath + "-wal", dbPath + "-shm", dbPath + "-journal"]
        for path in candidates {
            guard fm.fileExists(atPath: path) else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}
