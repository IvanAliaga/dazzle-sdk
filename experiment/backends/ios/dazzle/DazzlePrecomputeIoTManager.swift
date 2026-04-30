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

/// Ultimate-speed Valkey StorageBackend that pre-computes context block
/// fields during ingest so retrieval is a SINGLE HMGET — one command,
/// one round-trip, ~150-200 us.
///
/// During each ingest(), we update derived fields in the stats hash:
///   - recent_temps_csv: rolling window of last 10 temps as CSV
///   - recent_trend: pre-computed linear regression
///   - window_anomalies_csv: anomaly minutes in the current 20-min window
///
/// At read time, buildContextBlock() does ONE command: HMGET.
final class DazzlePrecomputeIoTManager: StorageBackend {

    let backendName: String = "Dazzle-Precompute"

    private let dazzle: Dazzle
    private let readings:  StreamKey
    private let stats:     HashKey
    private let anomalies: SortedSetKey
    private let decisions: ListKey

    // In-memory rolling window for pre-computation.
    // The server-side state is protected by the C mutex inside directCommand,
    // but this Swift-side array lives in user space — under concurrent ingest
    // it is not thread-safe. Protected by `lock` below (used by flush + ingest).
    private var recentTemps: [Double] = []
    private let lock = NSLock()

    init() {
        let client = DazzleServer.shared.client()
        self.dazzle    = client
        self.readings  = client.stream("sensor:readings")
        self.stats     = client.hash("sensor:stats")
        self.anomalies = client.sortedSet("sensor:anomalies")
        self.decisions = client.list("agent:decisions")
    }

    func flush() {
        _ = try? readings.deleteKey()
        _ = try? stats.deleteKey()
        _ = try? anomalies.deleteKey()
        _ = try? decisions.deleteKey()
        for i in 0...9 { _ = try? dazzle.hash("agent:checkpoint:\(i)").deleteKey() }
        lock.lock()
        recentTemps.removeAll()
        lock.unlock()
    }

    func ingest(_ reading: SensorReading) {
        lock.lock()
        defer { lock.unlock() }
        // Core writes
        _ = try? readings.add(
            fields: [
                ("temp",      String(reading.tempC)),
                ("humidity",  String(reading.humidity)),
                ("minute",    String(reading.minute)),
                ("anomalous", reading.anomalous ? "1" : "0"),
            ],
            maxLen: 200
        )
        _ = try? stats.incrByFloat("temp_sum", reading.tempC)
        _ = try? stats.incrBy("count", 1)
        _ = try? stats.set("latest_temp", String(reading.tempC))
        _ = try? stats.set("latest_minute", String(reading.minute))

        if reading.anomalous {
            _ = try? anomalies.add(score: Double(reading.minute), member: String(reading.minute))
            _ = try? stats.incrBy("anomaly_count", 1)
        }

        // Min/max (conditional)
        let curMin = (try? stats.get("min_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMin == nil || reading.tempC < curMin! {
            _ = try? stats.set("min_temp", String(reading.tempC))
        }
        let curMax = (try? stats.get("max_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMax == nil || reading.tempC > curMax! {
            _ = try? stats.set("max_temp", String(reading.tempC))
        }

        // Pre-compute derived fields
        recentTemps.append(reading.tempC)
        if recentTemps.count > 10 { recentTemps.removeFirst() }

        let tempsCsv = recentTemps.map { String(format: "%.1f", $0) }.joined(separator: ",")
        let trend = computeTrend(recentTemps)

        // Window anomalies (last 20 minutes from current reading)
        let windowStart = max(0, reading.minute - 20)
        let windowAnomalies = (try? anomalies.rangeByScore(
            min: Double(windowStart), max: Double(reading.minute)
        )) ?? []
        let windowAnomsCsv = windowAnomalies.joined(separator: ",")

        // Store derived fields
        _ = try? stats.set("recent_temps_csv", tempsCsv)
        _ = try? stats.set("recent_trend", trend)
        _ = try? stats.set("window_anomalies_csv", windowAnomsCsv)
        _ = try? stats.set("window_minutes", "20")
    }

    // MARK: - Context block: ONE HMGET = ONE round-trip

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        // ALL data in ONE command
        let fields = (try? stats.mGet(
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count",
            "recent_temps_csv", "recent_trend", "window_anomalies_csv"
        )) ?? []

        var lines: [String] = []

        let tempsCsv = fields.count > 5 ? fields[5] : nil
        if let csv = tempsCsv, !csv.isEmpty {
            lines.append("Last \(csv.split(separator: ",").count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(csv)")
            let trend = fields.count > 6 ? (fields[6] ?? "stable") : "stable"
            lines.append("Recent trend: \(trend)")
        }

        let count = fields.first.flatMap { $0 }.flatMap { Int($0) }
        if let count = count, count > 0 {
            let sum  = (fields.count > 1 ? fields[1] : nil).flatMap { Double($0) } ?? 0
            let minT = (fields.count > 2 ? fields[2] : nil).flatMap { Double($0) } ?? 0
            let maxT = (fields.count > 3 ? fields[3] : nil).flatMap { Double($0) } ?? 0
            let anomCnt = (fields.count > 4 ? fields[4] : nil).flatMap { Int($0) } ?? 0
            lines.append("Aggregate over \(count) readings: " +
                "avg=\(String(format: "%.1f", sum / Double(count)))\u{00B0}C, " +
                "min=\(String(format: "%.1f", minT))\u{00B0}C, " +
                "max=\(String(format: "%.1f", maxT))\u{00B0}C")
            lines.append("Total anomalies detected so far: \(anomCnt)")
        }

        let windowAnomsCsv = fields.count > 7 ? fields[7] : nil
        if let csv = windowAnomsCsv, !csv.isEmpty {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(csv)]")
        } else {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        var lines: [String] = []

        let fields = (try? stats.mGet("count", "temp_sum", "min_temp", "max_temp", "anomaly_count")) ?? []
        let count = fields.first.flatMap { $0 }.flatMap { Int($0) }
        if let count = count, count > 0 {
            let sum  = (fields.count > 1 ? fields[1] : nil).flatMap { Double($0) } ?? 0
            let minT = (fields.count > 2 ? fields[2] : nil).flatMap { Double($0) } ?? 0
            let maxT = (fields.count > 3 ? fields[3] : nil).flatMap { Double($0) } ?? 0
            let anomCnt = (fields.count > 4 ? fields[4] : nil).flatMap { Int($0) } ?? 0
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(count)")
            lines.append("Temperature range: \(String(format: "%.1f", minT))\u{00B0}C to " +
                "\(String(format: "%.1f", maxT))\u{00B0}C " +
                "(avg \(String(format: "%.1f", sum / Double(count)))\u{00B0}C)")
            lines.append("Total anomalies detected: \(anomCnt)")
        }

        let allAnomalyMins = (try? anomalies.rangeByScore(min: 0, max: 99999)) ?? []
        if !allAnomalyMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                "[\(allAnomalyMins.joined(separator: ", "))]")
        }

        let decisionLines = (try? decisions.range(0, -1)) ?? []
        if !decisionLines.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (idx, decision) in decisionLines.enumerated() {
                lines.append("  Checkpoint \(idx + 1): \(decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"
        _ = try? dazzle.hash("agent:checkpoint:\(index)").setAll([
            "minute":   String(minute),
            "anomaly":  anomalyDetected ? "1" : "0",
            "severity": severity,
            "trend":    trend,
        ])
        _ = try? decisions.rpush(decision)
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

    var backendSizeMethod: String { "valkey:used_memory_dataset" }

    func backendSizeBytes() -> Int64 {
        guard let info = DazzleServer.shared.directCommand("INFO memory") else { return -1 }
        return parseValkeyUsedMemoryDataset(info)
    }

    func backendSizeBreakdown() -> [String: Int64]? {
        guard let info = DazzleServer.shared.directCommand("INFO memory") else { return nil }
        return parseValkeyMemoryStats(info)
    }
}
