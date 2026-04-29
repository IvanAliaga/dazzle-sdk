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

/// Optimized Valkey StorageBackend that uses directPipeline to batch
/// all writes AND reads into minimal pipe round-trips.
///
/// The naive DazzleContextManager issues 6-8 separate directCommand calls
/// per buildContextBlock. This version batches them via directPipelineArgs
/// (in-process, pre-split argv — no space-splitting issues).
final class DazzlePipelineContextManager: StorageBackend {

    let backendName: String = "Dazzle-Pipeline"

    private let dazzle: Dazzle
    private let readings:  StreamKey
    private let stats:     HashKey
    private let anomalies: SortedSetKey
    private let decisions: ListKey

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
    }

    // MARK: - Ingest (batched pipeline)

    func ingest(_ reading: SensorReading) {
        var commands: [[String]] = []

        commands.append(["XADD", "sensor:readings", "MAXLEN", "~", "200", "*",
            "temp", String(reading.tempC),
            "humidity", String(reading.humidity),
            "minute", String(reading.minute),
            "anomalous", reading.anomalous ? "1" : "0"])
        commands.append(["HINCRBYFLOAT", "sensor:stats", "temp_sum", String(reading.tempC)])
        commands.append(["HINCRBY", "sensor:stats", "count", "1"])
        commands.append(["HSET", "sensor:stats", "latest_temp", String(reading.tempC)])
        commands.append(["HSET", "sensor:stats", "latest_minute", String(reading.minute)])

        if reading.anomalous {
            commands.append(["ZADD", "sensor:anomalies", String(reading.minute), String(reading.minute)])
            commands.append(["HINCRBY", "sensor:stats", "anomaly_count", "1"])
        }

        _ = DazzleServer.shared.directPipelineArgs(commands)

        // Min/max needs conditional (can't fully pipeline)
        let curMin = (try? stats.get("min_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMin == nil || reading.tempC < curMin! {
            _ = try? stats.set("min_temp", String(reading.tempC))
        }
        let curMax = (try? stats.get("max_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMax == nil || reading.tempC > curMax! {
            _ = try? stats.set("max_temp", String(reading.tempC))
        }
    }

    // MARK: - Context block (batched read pipeline)

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        let windowStart = max(0, currentMinute - windowMinutes)

        // Batch ALL reads in one pipeline
        let replies = DazzleServer.shared.directPipelineArgs([
            ["XREVRANGE", "sensor:readings", "+", "-", "COUNT", "10"],
            ["HMGET", "sensor:stats", "count", "temp_sum", "min_temp", "max_temp", "anomaly_count"],
            ["ZRANGEBYSCORE", "sensor:anomalies", String(windowStart), String(currentMinute)],
        ])

        var lines: [String] = []

        // Parse recent readings from XREVRANGE reply
        if let readingsReply = replies.first, !readingsReply.isEmpty {
            if let parsed = try? RespParser.parse(readingsReply) {
                let entries = parsed.asArray
                var recentTemps: [Double] = []
                for item in entries.reversed() {
                    let pair = item.asArray
                    if pair.count >= 2 {
                        let fields = pair[1].asArray
                        var i = 0
                        while i < fields.count - 1 {
                            if fields[i].asBulkOrNil == "temp" {
                                if let t = fields[i + 1].asBulkOrNil.flatMap({ Double($0) }) {
                                    recentTemps.append(t)
                                }
                            }
                            i += 2
                        }
                    }
                }
                if !recentTemps.isEmpty {
                    let formatted = recentTemps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                    lines.append("Last \(recentTemps.count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(formatted)")
                    lines.append("Recent trend: \(computeTrend(recentTemps))")
                }
            }
        }

        // Parse stats from HMGET reply
        if replies.count > 1 {
            let statsReply = replies[1]
            if !statsReply.isEmpty, let parsed = try? RespParser.parse(statsReply) {
                let arr = parsed.asArray
                if let count = arr.first?.asBulkOrNil.flatMap({ Int($0) }), count > 0 {
                    let sum  = (arr.count > 1 ? arr[1].asBulkOrNil : nil).flatMap { Double($0) } ?? 0
                    let minT = (arr.count > 2 ? arr[2].asBulkOrNil : nil).flatMap { Double($0) } ?? 0
                    let maxT = (arr.count > 3 ? arr[3].asBulkOrNil : nil).flatMap { Double($0) } ?? 0
                    let anomCnt = (arr.count > 4 ? arr[4].asBulkOrNil : nil).flatMap { Int($0) } ?? 0
                    lines.append("Aggregate over \(count) readings: " +
                        "avg=\(String(format: "%.1f", sum / Double(count)))\u{00B0}C, " +
                        "min=\(String(format: "%.1f", minT))\u{00B0}C, " +
                        "max=\(String(format: "%.1f", maxT))\u{00B0}C")
                    lines.append("Total anomalies detected so far: \(anomCnt)")
                }
            }
        }

        // Parse anomalies from ZRANGEBYSCORE reply
        if replies.count > 2 {
            let anomReply = replies[2]
            if !anomReply.isEmpty, let parsed = try? RespParser.parse(anomReply) {
                let windowAnomalies = parsed.asArray.compactMap { $0.asBulkOrNil }
                if windowAnomalies.isEmpty {
                    lines.append("No anomalies in the last \(windowMinutes) minutes.")
                } else {
                    lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                        "(minute numbers, not temperatures): [\(windowAnomalies.joined(separator: ", "))]")
                }
            } else {
                lines.append("No anomalies in the last \(windowMinutes) minutes.")
            }
        } else {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        let replies = DazzleServer.shared.directPipelineArgs([
            ["HMGET", "sensor:stats", "count", "temp_sum", "min_temp", "max_temp", "anomaly_count"],
            ["ZRANGEBYSCORE", "sensor:anomalies", "0", "99999"],
            ["LRANGE", "agent:decisions", "0", "-1"],
        ])

        var lines: [String] = []

        if let statsReply = replies.first, !statsReply.isEmpty,
           let parsed = try? RespParser.parse(statsReply) {
            let arr = parsed.asArray
            if let count = arr.first?.asBulkOrNil.flatMap({ Int($0) }), count > 0 {
                let sum  = (arr.count > 1 ? arr[1].asBulkOrNil : nil).flatMap { Double($0) } ?? 0
                let minT = (arr.count > 2 ? arr[2].asBulkOrNil : nil).flatMap { Double($0) } ?? 0
                let maxT = (arr.count > 3 ? arr[3].asBulkOrNil : nil).flatMap { Double($0) } ?? 0
                let anomCnt = (arr.count > 4 ? arr[4].asBulkOrNil : nil).flatMap { Int($0) } ?? 0
                lines.append("=== Full Session Stats ===")
                lines.append("Total readings: \(count)")
                lines.append("Temperature range: \(String(format: "%.1f", minT))\u{00B0}C to " +
                    "\(String(format: "%.1f", maxT))\u{00B0}C " +
                    "(avg \(String(format: "%.1f", sum / Double(count)))\u{00B0}C)")
                lines.append("Total anomalies detected: \(anomCnt)")
            }
        }

        if replies.count > 1 {
            let anomReply = replies[1]
            if !anomReply.isEmpty, let parsed = try? RespParser.parse(anomReply) {
                let anoms = parsed.asArray.compactMap { $0.asBulkOrNil }
                if !anoms.isEmpty {
                    lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                        "[\(anoms.joined(separator: ", "))]")
                }
            }
        }

        if replies.count > 2 {
            let decReply = replies[2]
            if !decReply.isEmpty, let parsed = try? RespParser.parse(decReply) {
                let decs = parsed.asArray.compactMap { $0.asBulkOrNil }
                if !decs.isEmpty {
                    lines.append("=== Monitoring Agent Decisions ===")
                    for (idx, decision) in decs.enumerated() {
                        lines.append("  Checkpoint \(idx + 1): \(decision)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"

        _ = DazzleServer.shared.directPipelineArgs([
            ["HSET", "agent:checkpoint:\(index)",
                "minute", String(minute),
                "anomaly", anomalyDetected ? "1" : "0",
                "severity", severity,
                "trend", trend],
            ["RPUSH", "agent:decisions", decision],
        ])
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
