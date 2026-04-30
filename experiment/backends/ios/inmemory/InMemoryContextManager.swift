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

/// In-memory StorageBackend using plain Swift collections.
///
/// This is the "no database at all" baseline. It stores everything in
/// arrays and dictionaries — zero persistence, zero overhead, zero
/// library dependency. The purpose is to show that raw retrieval latency
/// is dominated by computation (context block string building), not by
/// the storage engine.
final class InMemoryContextManager: StorageBackend {

    let backendName: String = "InMemory"

    private struct ReadingEntry {
        let minute: Int
        let temp: Double
        let humidity: Double
        let anomalous: Bool
    }

    private struct CheckpointEntry {
        let minute: Int
        let anomaly: Bool
        let severity: String
        let trend: String
    }

    private var readings:    [ReadingEntry] = []
    private var stats:       [String: Double] = [:]
    private var anomalyMins: [Int] = []             // sorted by minute
    private var decisions:   [String] = []           // ordered by CP index
    private var checkpoints: [Int: CheckpointEntry] = [:]

    // MARK: - Lifecycle

    func flush() {
        readings.removeAll()
        stats.removeAll()
        anomalyMins.removeAll()
        decisions.removeAll()
        checkpoints.removeAll()
    }

    // MARK: - Ingest

    func ingest(_ reading: SensorReading) {
        readings.append(ReadingEntry(
            minute:    reading.minute,
            temp:      reading.tempC,
            humidity:  reading.humidity,
            anomalous: reading.anomalous
        ))

        // Trim to 200 — equivalent to Valkey MAXLEN ~200
        if readings.count > 210 {
            readings.removeFirst(readings.count - 200)
        }

        // Running stats
        stats["temp_sum"]      = (stats["temp_sum"] ?? 0) + reading.tempC
        stats["count"]         = (stats["count"] ?? 0) + 1
        stats["latest_temp"]   = reading.tempC
        stats["latest_minute"] = Double(reading.minute)

        let curMin = stats["min_temp"]
        if curMin == nil || reading.tempC < curMin! {
            stats["min_temp"] = reading.tempC
        }
        let curMax = stats["max_temp"]
        if curMax == nil || reading.tempC > curMax! {
            stats["max_temp"] = reading.tempC
        }

        if reading.anomalous {
            if !anomalyMins.contains(reading.minute) {
                // Insert sorted via binary search
                let idx = anomalyMins.insertionIndex(of: reading.minute)
                anomalyMins.insert(reading.minute, at: idx)
            }
            stats["anomaly_count"] = (stats["anomaly_count"] ?? 0) + 1
        }
    }

    // MARK: - Context block (byte-identical to Valkey/SQLite)

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        var lines: [String] = []

        // Last 10 readings (oldest -> newest)
        let recent = readings.suffix(10)
        let recentTemps = recent.map { $0.temp }

        if !recentTemps.isEmpty {
            let formatted = recentTemps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            lines.append("Last \(recentTemps.count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(formatted)")
            lines.append("Recent trend: \(computeTrend(Array(recentTemps)))")
        }

        // Aggregate stats
        if let s = readStats() {
            lines.append("Aggregate over \(s.count) readings: " +
                "avg=\(String(format: "%.1f", s.avgTemp))\u{00B0}C, " +
                "min=\(String(format: "%.1f", s.minTemp))\u{00B0}C, " +
                "max=\(String(format: "%.1f", s.maxTemp))\u{00B0}C")
            lines.append("Total anomalies detected so far: \(s.anomalyCount)")
        }

        // Anomalies in window
        let windowStart = max(0, currentMinute - windowMinutes)
        let windowAnomalies = anomalyMins.filter { $0 >= windowStart && $0 <= currentMinute }

        if windowAnomalies.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(windowAnomalies.map(String.init).joined(separator: ", "))]")
        }

        return lines.joined(separator: "\n")
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

        if !anomalyMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                "[\(anomalyMins.map(String.init).joined(separator: ", "))]")
        }

        if !decisions.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (idx, decision) in decisions.enumerated() {
                lines.append("  Checkpoint \(idx + 1): \(decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Decision storage

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"

        checkpoints[index] = CheckpointEntry(
            minute:   minute,
            anomaly:  anomalyDetected,
            severity: severity,
            trend:    trend
        )

        // Ensure decisions list is large enough
        while decisions.count <= index { decisions.append("") }
        decisions[index] = decision
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
        guard let countD = stats["count"], countD > 0 else { return nil }
        let c       = Int(countD)
        let sum     = stats["temp_sum"] ?? 0
        let minTemp = stats["min_temp"] ?? 0
        let maxTemp = stats["max_temp"] ?? 0
        let anomCnt = Int(stats["anomaly_count"] ?? 0)
        return RunningStats(
            count:        c,
            avgTemp:      sum / Double(c),
            minTemp:      minTemp,
            maxTemp:      maxTemp,
            anomalyCount: anomCnt
        )
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

    // MARK: - Footprint accounting

    var backendSizeMethod: String { "inmemory:struct_estimate" }

    /// Conservative byte estimate of the live Swift objects this backend
    /// keeps. ARM64 lays each class header at 16 bytes, plus aligned
    /// payload — we count payload only and ignore Swift's malloc bucket
    /// rounding, so the result is a lower bound (matches Android's
    /// `inmemory:struct_estimate` accounting).
    ///
    /// Components (per-entry, in bytes):
    ///   - ReadingEntry       : 8 minute + 8 temp + 8 humidity + 1 anom + pad ≈ 32
    ///   - anomalyMins (Int)  : 8 each
    ///   - decisions (String) : 16 hdr + 2 × utf8 length
    ///   - checkpoints        : ~64 per entry incl. severity/trend strings
    ///   - stats              : ~32 per (key, Double) Dictionary entry
    func backendSizeBytes() -> Int64 {
        var total: Int64 = 0
        total += Int64(readings.count) * 32
        total += Int64(anomalyMins.count) * 8
        total += decisions.reduce(0) { $0 + Int64(16 + $1.utf8.count * 2) }
        total += Int64(checkpoints.count) * 64
        total += stats.reduce(0) { $0 + Int64(32 + $1.key.utf8.count * 2) }
        return total
    }
}

// MARK: - Array binary search helper

private extension Array where Element == Int {
    func insertionIndex(of value: Int) -> Int {
        var lo = startIndex, hi = endIndex
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
