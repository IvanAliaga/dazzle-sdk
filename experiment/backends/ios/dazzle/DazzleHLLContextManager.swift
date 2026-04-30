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

/// Valkey backend demonstrating HyperLogLog (HLL) for token-efficient
/// context blocks — a probabilistic data structure that estimates
/// cardinality with ~0.81% error in a fixed 12 KB footprint.
///
/// Instead of listing every anomaly minute individually in the context,
/// this backend uses HLL to report:
///   "~11 anomalies detected (estimated via HLL, 4 distinct patterns)"
/// in a CONSTANT number of tokens regardless of data volume.
final class DazzleHLLContextManager: StorageBackend {

    let backendName: String = "Dazzle-HLL"

    private let dazzle: Dazzle
    private let readings:     StreamKey
    private let stats:        HashKey
    private let anomalies:    SortedSetKey
    private let decisions:    ListKey
    private let anomalyHLL:     HyperLogLogKey
    private let anomalyTypeHLL: HyperLogLogKey

    init() {
        let client = DazzleServer.shared.client()
        self.dazzle         = client
        self.readings       = client.stream("sensor:readings")
        self.stats          = client.hash("sensor:stats")
        self.anomalies      = client.sortedSet("sensor:anomalies")
        self.decisions      = client.list("agent:decisions")
        self.anomalyHLL     = client.hyperLogLog("sensor:anomaly_hll")
        self.anomalyTypeHLL = client.hyperLogLog("sensor:anomaly_type_hll")
    }

    func flush() {
        _ = try? readings.deleteKey()
        _ = try? stats.deleteKey()
        _ = try? anomalies.deleteKey()
        _ = try? decisions.deleteKey()
        _ = try? anomalyHLL.deleteKey()
        _ = try? anomalyTypeHLL.deleteKey()
        for i in 0...9 { _ = try? dazzle.hash("agent:checkpoint:\(i)").deleteKey() }
    }

    func ingest(_ reading: SensorReading) {
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

        let curMin = (try? stats.get("min_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMin == nil || reading.tempC < curMin! {
            _ = try? stats.set("min_temp", String(reading.tempC))
        }
        let curMax = (try? stats.get("max_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMax == nil || reading.tempC > curMax! {
            _ = try? stats.set("max_temp", String(reading.tempC))
        }

        if reading.anomalous {
            _ = try? anomalies.add(score: Double(reading.minute), member: String(reading.minute))
            _ = try? stats.incrBy("anomaly_count", 1)

            // HLL: track unique anomaly minute
            _ = try? anomalyHLL.add(String(reading.minute))

            // HLL: classify and track distinct anomaly types
            let anomalyType: String
            switch reading.tempC {
            case let t where t > 32.0: anomalyType = "spike_high"
            case let t where t > 28.0: anomalyType = "spike_moderate"
            case let t where t < 2.0:  anomalyType = "dropout_severe"
            case let t where t < 5.0:  anomalyType = "dropout"
            default:                   anomalyType = "oscillation"
            }
            _ = try? anomalyTypeHLL.add(anomalyType)
        }
    }

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        var lines: [String] = []

        if let entries = try? readings.revRange(count: 10) {
            let temps = entries
                .compactMap { $0.fields.first(where: { $0.0 == "temp" }).flatMap { Double($0.1) } }
                .reversed()
            let tempsArr = Array(temps)
            if !tempsArr.isEmpty {
                let formatted = tempsArr.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                lines.append("Last \(tempsArr.count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(formatted)")
                lines.append("Recent trend: \(computeTrend(tempsArr))")
            }
        }

        if let s = readStats() {
            lines.append("Aggregate over \(s.count) readings: " +
                "avg=\(String(format: "%.1f", s.avgTemp))\u{00B0}C, " +
                "min=\(String(format: "%.1f", s.minTemp))\u{00B0}C, " +
                "max=\(String(format: "%.1f", s.maxTemp))\u{00B0}C")

            // HLL: report cardinality instead of listing all anomalies
            let uniqueAnomalies = (try? anomalyHLL.count()) ?? 0
            let distinctTypes = (try? anomalyTypeHLL.count()) ?? 0
            lines.append("Total anomalies detected so far: ~\(uniqueAnomalies) (HLL estimate, \(distinctTypes) distinct patterns)")
        }

        let windowStart = max(0, currentMinute - windowMinutes)
        let windowAnomalies = (try? anomalies.rangeByScore(
            min: Double(windowStart), max: Double(currentMinute)
        )) ?? []
        if windowAnomalies.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            // Still list window anomalies (small, bounded by window size)
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(windowAnomalies.joined(separator: ", "))]")
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

            // HLL: compact cardinality instead of full list
            let uniqueAnomalies = (try? anomalyHLL.count()) ?? 0
            let distinctTypes = (try? anomalyTypeHLL.count()) ?? 0
            lines.append("Total anomalies detected: ~\(uniqueAnomalies) (\(distinctTypes) distinct anomaly patterns)")
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

    // MARK: - Private helpers

    private struct RunningStats {
        let count: Int, avgTemp: Double, minTemp: Double
        let maxTemp: Double, anomalyCount: Int
    }

    private func statField(_ field: String) -> String? {
        do { return try stats.get(field) } catch { return nil }
    }

    private func readStats() -> RunningStats? {
        // Phase 1 snapshot HMGET — one FFI crossing instead of five HGETs.
        let v = (try? stats.mGetDirect(
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count"
        )) ?? [nil, nil, nil, nil, nil]
        guard let countStr = v[0], let count = Int(countStr), count > 0 else { return nil }
        let sum     = v[1].flatMap { Double($0) } ?? 0
        let minTemp = v[2].flatMap { Double($0) } ?? 0
        let maxTemp = v[3].flatMap { Double($0) } ?? 0
        let anomCnt = v[4].flatMap { Int($0) } ?? 0
        return RunningStats(count: count, avgTemp: sum / Double(count),
                           minTemp: minTemp, maxTemp: maxTemp, anomalyCount: anomCnt)
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
