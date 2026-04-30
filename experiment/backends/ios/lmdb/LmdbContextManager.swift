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

/// LMDB-based [StorageBackend] for the Sequential Monitoring Agent.
///
/// Mirrors `LmdbContextManager.kt` on Android byte-for-byte: same key
/// schema, same five named sub-databases, same trim cap, same string
/// encoding for stat values. The shim is a flat C interface
/// (`lmdb_ios.[ch]`) declared in the storage app's bridging header so we
/// avoid a module-map dance for a single-target dependency.
final class LmdbContextManager: StorageBackend {

    let backendName: String = "LMDB"

    private let dbDir: URL
    private var readingCounter: Int64 = 0

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("lmdb-experiment", isDirectory: true)

        // Wipe any prior run so storage_only delta reflects a cold start.
        // LMDB pre-allocates the map file and never shrinks it, so a
        // surviving data.mdb would carry the previous run's high-water
        // mark forward and make the delta meaningless (~0 bytes).
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbDir = dir

        _ = dir.path.withCString { lmdb_ios_open($0, 6, 64) }
    }

    deinit { lmdb_ios_close() }

    // MARK: – Lifecycle

    func flush() {
        _ = "readings".withCString    { lmdb_ios_drop($0) }
        _ = "stats".withCString       { lmdb_ios_drop($0) }
        _ = "anomalies".withCString   { lmdb_ios_drop($0) }
        _ = "decisions".withCString   { lmdb_ios_drop($0) }
        _ = "checkpoints".withCString { lmdb_ios_drop($0) }
        readingCounter = 0
    }

    // MARK: – Ingest

    func ingest(_ reading: SensorReading) {
        let id = readingCounter
        readingCounter += 1
        let key = String(format: "r:%010lld", id)
        let value = "\(reading.minute),\(reading.tempC),\(reading.humidity),\(reading.anomalous ? 1 : 0)"
        _ = put(db: "readings", key: key, value: value)

        if readingCounter > 210 {
            let keys = allKeys(in: "readings")
            if keys.count > 200 {
                for i in 0 ..< keys.count - 200 {
                    _ = del(db: "readings", key: keys[i])
                }
            }
        }

        upsertStat("temp_sum",      reading.tempC, increment: true)
        upsertStat("count",         1.0,           increment: true)
        upsertStat("latest_temp",   reading.tempC, increment: false)
        upsertStat("latest_minute", Double(reading.minute), increment: false)

        if let curMin = getStat("min_temp") {
            if reading.tempC < curMin { upsertStat("min_temp", reading.tempC, increment: false) }
        } else {
            upsertStat("min_temp", reading.tempC, increment: false)
        }
        if let curMax = getStat("max_temp") {
            if reading.tempC > curMax { upsertStat("max_temp", reading.tempC, increment: false) }
        } else {
            upsertStat("max_temp", reading.tempC, increment: false)
        }

        if reading.anomalous {
            _ = put(db: "anomalies", key: String(reading.minute), value: "1")
            upsertStat("anomaly_count", 1.0, increment: true)
        }
    }

    // MARK: – Context block

    func buildContextBlock(currentMinute: Int, windowMinutes: Int) -> String {
        var lines: [String] = []

        let allReadingKeys = allKeys(in: "readings")
        var recentTemps: [Double] = []
        if !allReadingKeys.isEmpty {
            let last10 = allReadingKeys.suffix(10)
            for k in last10 {
                if let v = get(db: "readings", key: k) {
                    let parts = v.split(separator: ",")
                    if parts.count >= 2, let t = Double(parts[1]) { recentTemps.append(t) }
                }
            }
        }

        if !recentTemps.isEmpty {
            let formatted = recentTemps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            lines.append("Last \(recentTemps.count) temperatures (oldest→newest, °C): \(formatted)")
            lines.append("Recent trend: \(computeTrend(recentTemps))")
        }

        if let s = readStats() {
            lines.append("Aggregate over \(s.count) readings: " +
                         "avg=\(String(format: "%.1f", s.avgTemp))°C, " +
                         "min=\(String(format: "%.1f", s.minTemp))°C, " +
                         "max=\(String(format: "%.1f", s.maxTemp))°C")
            lines.append("Total anomalies detected so far: \(s.anomalyCount)")
        }

        let windowStart = max(0, currentMinute - windowMinutes)
        let anomalyKeys = allKeys(in: "anomalies")
        let windowAnomalies = anomalyKeys
            .compactMap { Int($0) }
            .filter { $0 >= windowStart && $0 <= currentMinute }
            .sorted()

        if windowAnomalies.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                         "(minute numbers, not temperatures): " +
                         "[\(windowAnomalies.map(String.init).joined(separator: ", "))]")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        var lines: [String] = []

        if let s = readStats() {
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(s.count)")
            lines.append("Temperature range: \(String(format: "%.1f", s.minTemp))°C to " +
                         "\(String(format: "%.1f", s.maxTemp))°C " +
                         "(avg \(String(format: "%.1f", s.avgTemp))°C)")
            lines.append("Total anomalies detected: \(s.anomalyCount)")
        }

        let allAnomalyMins = allKeys(in: "anomalies").compactMap { Int($0) }.sorted()
        if !allAnomalyMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                         "[\(allAnomalyMins.map(String.init).joined(separator: ", "))]")
        }

        let decisionKeys = allKeys(in: "decisions")
        let decisionList: [(Int, String)] = decisionKeys.compactMap { k in
            guard let idx = Int(k), let v = get(db: "decisions", key: k) else { return nil }
            return (idx, v)
        }.sorted { $0.0 < $1.0 }

        if !decisionList.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (idx, decision) in decisionList {
                lines.append("  Checkpoint \(idx + 1): \(decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: – Decision storage

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"
        _ = put(db: "checkpoints", key: String(index),
                value: "\(minute),\(anomalyDetected ? 1 : 0),\(severity),\(trend)")
        _ = put(db: "decisions", key: String(index), value: decision)
    }

    // MARK: – Private helpers

    private struct RunningStats {
        let count: Int
        let avgTemp: Double
        let minTemp: Double
        let maxTemp: Double
        let anomalyCount: Int
    }

    private func readStats() -> RunningStats? {
        guard let countD = getStat("count") else { return nil }
        let count = Int(countD)
        if count == 0 { return nil }
        let sum = getStat("temp_sum") ?? 0
        return RunningStats(
            count:        count,
            avgTemp:      sum / Double(count),
            minTemp:      getStat("min_temp") ?? 0,
            maxTemp:      getStat("max_temp") ?? 0,
            anomalyCount: Int(getStat("anomaly_count") ?? 0)
        )
    }

    private func getStat(_ key: String) -> Double? {
        guard let v = get(db: "stats", key: key) else { return nil }
        return Double(v)
    }

    private func upsertStat(_ key: String, _ value: Double, increment: Bool) {
        let existing = getStat(key)
        let newVal = increment && existing != nil ? existing! + value : value
        _ = put(db: "stats", key: key, value: String(newVal))
    }

    private func computeTrend(_ temps: [Double]) -> String {
        if temps.count < 2 { return "stable" }
        let n = temps.count
        let meanX = Double(n - 1) / 2.0
        let meanY = temps.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0 ..< n {
            num += (Double(i) - meanX) * (temps[i] - meanY)
            den += (Double(i) - meanX) * (Double(i) - meanX)
        }
        let slope = den != 0 ? num / den : 0
        if slope >  0.15 { return "increasing" }
        if slope < -0.15 { return "decreasing" }
        return "stable"
    }

    // MARK: – C shim wrappers

    private func put(db: String, key: String, value: String) -> Bool {
        db.withCString { dbp in
            key.withCString { kp in
                value.withCString { vp in
                    lmdb_ios_put(dbp, kp, vp)
                }
            }
        }
    }

    private func get(db: String, key: String) -> String? {
        db.withCString { dbp in
            key.withCString { kp in
                guard let raw = lmdb_ios_get(dbp, kp) else { return nil }
                let s = String(cString: raw)
                free(raw)
                return s
            }
        }
    }

    private func del(db: String, key: String) -> Bool {
        db.withCString { dbp in key.withCString { kp in lmdb_ios_delete(dbp, kp) } }
    }

    private func allKeys(in db: String) -> [String] {
        db.withCString { dbp in
            var count: size_t = 0
            guard let raw = lmdb_ios_get_all_keys(dbp, &count) else { return [] }
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0 ..< count {
                if let p = raw[i] { out.append(String(cString: p)) }
            }
            lmdb_ios_free_keys(raw, count)
            return out
        }
    }

    // MARK: – Footprint accounting

    let backendSizeMethod: String = "lmdb:dir_st_blocks"

    /// Sum `st_blocks * 512` across the LMDB directory — same accounting
    /// the Android side uses (`du -k` semantics). Forces a sync first
    /// because the env was opened with `MDB_NOSYNC | MDB_WRITEMAP`, so
    /// dirty mmap pages need to land on disk before stat() reports
    /// truthful block counts.
    func backendSizeBytes() -> Int64 {
        guard FileManager.default.fileExists(atPath: dbDir.path) else { return 0 }
        _ = lmdb_ios_sync(true)
        var total: Int64 = 0
        if let it = FileManager.default.enumerator(at: dbDir, includingPropertiesForKeys: nil) {
            for case let url as URL in it {
                var st = Darwin.stat()
                if Darwin.lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                    total += Int64(st.st_blocks) * 512
                } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let size = attrs[.size] as? NSNumber {
                    total += size.int64Value
                }
            }
        }
        return total
    }
}
