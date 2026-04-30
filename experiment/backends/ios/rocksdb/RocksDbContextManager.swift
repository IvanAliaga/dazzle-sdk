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

/// RocksDB-based [StorageBackend] for the Sequential Monitoring Agent.
///
/// Mirrors `RocksDbContextManager.kt` line-for-line: same prefix-keyed
/// pseudo-namespaces (`readings:`, `stats:`, `anomalies:`, `decisions:`,
/// `checkpoints:`) over the default column family, same READINGS_CAP=200
/// soft cap, same amortized trim policy (only every TRIM_BATCH=32 ingests
/// once we've gone past the cap), and the same `st_blocks * 512`
/// footprint accounting that matches `du -k` semantics.
///
/// The C surface (`rocksdb_ios.[ch]`) wraps RocksDB's stable `rocksdb/c.h`
/// API in a global-handle shim so the Swift side stays one-to-one with
/// the Kotlin `RocksDbBridge` static methods.
final class RocksDbContextManager: StorageBackend {

    let backendName: String = "RocksDB"

    private let dbDir: URL
    private var readingCounter: Int64 = 0

    private static let READINGS_CAP: Int = 200
    private static let TRIM_BATCH: Int64 = 32

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("rocksdb-experiment", isDirectory: true)

        // Wipe any prior run so storage_only delta reflects a cold start —
        // RocksDB keeps WAL + SST + manifest from previous runs and would
        // otherwise carry the previous high-water mark forward.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbDir = dir

        _ = dir.path.withCString { rocksdb_ios_open($0) }
    }

    deinit { rocksdb_ios_close() }

    // MARK: – Lifecycle

    func flush() {
        _ = "readings:".withCString    { rocksdb_ios_delete_with_prefix($0) }
        _ = "stats:".withCString       { rocksdb_ios_delete_with_prefix($0) }
        _ = "anomalies:".withCString   { rocksdb_ios_delete_with_prefix($0) }
        _ = "decisions:".withCString   { rocksdb_ios_delete_with_prefix($0) }
        _ = "checkpoints:".withCString { rocksdb_ios_delete_with_prefix($0) }
        readingCounter = 0
    }

    // MARK: – Ingest

    func ingest(_ reading: SensorReading) {
        let id = readingCounter
        readingCounter += 1

        let key = String(format: "readings:%010lld", id)
        let value = "\(reading.minute),\(reading.tempC),\(reading.humidity),\(reading.anomalous ? 1 : 0)"
        _ = put(key: key, value: value)

        // Trim to ~200 entries. Same amortized policy as Android: only
        // run the prefix-scan every TRIM_BATCH ingests once we've gone
        // past the soft cap, so the per-ingest cost stays O(1).
        if readingCounter > Int64(Self.READINGS_CAP) + Self.TRIM_BATCH &&
           readingCounter % Self.TRIM_BATCH == 0 {
            let keys = keysWithPrefix("readings:")
            if keys.count > Self.READINGS_CAP {
                let drop = keys.count - Self.READINGS_CAP
                for i in 0 ..< drop { _ = del(key: keys[i]) }
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
            _ = put(key: "anomalies:\(reading.minute)", value: "1")
            upsertStat("anomaly_count", 1.0, increment: true)
        }
    }

    // MARK: – Context block

    func buildContextBlock(currentMinute: Int, windowMinutes: Int) -> String {
        var lines: [String] = []

        let readingKeys = keysWithPrefix("readings:")
        var recentTemps: [Double] = []
        if !readingKeys.isEmpty {
            let last10 = readingKeys.suffix(10)
            for k in last10 {
                if let v = get(key: k) {
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
        let anomalyKeys = keysWithPrefix("anomalies:")
        let windowAnomalies = anomalyKeys
            .compactMap { Int($0.dropFirst("anomalies:".count)) }
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

        let allAnomalyMins = keysWithPrefix("anomalies:")
            .compactMap { Int($0.dropFirst("anomalies:".count)) }
            .sorted()
        if !allAnomalyMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                         "[\(allAnomalyMins.map(String.init).joined(separator: ", "))]")
        }

        let decisionKeys = keysWithPrefix("decisions:")
        let decisionList: [(Int, String)] = decisionKeys.compactMap { k in
            guard let idx = Int(k.dropFirst("decisions:".count)),
                  let v = get(key: k) else { return nil }
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
        _ = put(key: "checkpoints:\(index)",
                value: "\(minute),\(anomalyDetected ? 1 : 0),\(severity),\(trend)")
        _ = put(key: "decisions:\(index)", value: decision)
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
        guard let v = get(key: "stats:\(key)") else { return nil }
        return Double(v)
    }

    private func upsertStat(_ key: String, _ value: Double, increment: Bool) {
        let existing = getStat(key)
        let newVal = increment && existing != nil ? existing! + value : value
        _ = put(key: "stats:\(key)", value: String(newVal))
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

    private func put(key: String, value: String) -> Bool {
        key.withCString { kp in
            value.withCString { vp in
                rocksdb_ios_put(kp, vp)
            }
        }
    }

    private func get(key: String) -> String? {
        key.withCString { kp in
            guard let raw = rocksdb_ios_get(kp) else { return nil }
            let s = String(cString: raw)
            free(raw)
            return s
        }
    }

    private func del(key: String) -> Bool {
        key.withCString { kp in rocksdb_ios_delete(kp) }
    }

    private func keysWithPrefix(_ prefix: String) -> [String] {
        prefix.withCString { pp in
            var count: size_t = 0
            guard let raw = rocksdb_ios_get_keys_with_prefix(pp, &count) else { return [] }
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0 ..< count {
                if let p = raw[i] { out.append(String(cString: p)) }
            }
            rocksdb_ios_free_keys(raw, count)
            return out
        }
    }

    // MARK: – Footprint accounting

    let backendSizeMethod: String = "rocksdb:dir_st_blocks"

    /// Sum `st_blocks * 512` across the RocksDB directory — matches the
    /// Android side (`du -k` semantics). RocksDB writes SST files, WAL,
    /// MANIFEST, OPTIONS and LOCK on every commit so no explicit sync is
    /// needed before stat()ing.
    func backendSizeBytes() -> Int64 {
        guard FileManager.default.fileExists(atPath: dbDir.path) else { return 0 }
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
