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

/// Optimized Valkey StorageBackend that uses Lua scripting to demonstrate
/// that Valkey's capabilities enable faster retrieval than any other
/// backend when used correctly.
///
/// Reads use a single EVAL Lua script that executes all queries
/// server-side and returns the assembled data as a single array
/// (1 round-trip instead of 6-8).
final class DazzleLuaContextManager: StorageBackend {

    let backendName: String = "Dazzle-Lua"

    private let dazzle: Dazzle
    private let readings:  StreamKey
    private let stats:     HashKey
    private let anomalies: SortedSetKey
    private let decisions: ListKey

    // Lua scripts (loaded once, cached by SHA)
    private let contextBlockScript: LuaScript
    private let synthesisScript:    LuaScript

    init() {
        let client = DazzleServer.shared.client()
        self.dazzle    = client
        self.readings  = client.stream("sensor:readings")
        self.stats     = client.hash("sensor:stats")
        self.anomalies = client.sortedSet("sensor:anomalies")
        self.decisions = client.list("agent:decisions")

        // Fetches ALL data in ONE round-trip, returns raw values as flat array.
        // Swift formats the output (handling Unicode chars like degree and arrow).
        self.contextBlockScript = client.script("""
            local result = {}
            local entries = redis.call('XREVRANGE', KEYS[1], '+', '-', 'COUNT', 10)
            local temps = {}
            for i = #entries, 1, -1 do
                local fields = entries[i][2]
                for j = 1, #fields, 2 do
                    if fields[j] == 'temp' then temps[#temps+1] = fields[j+1] end
                end
            end
            result[1] = table.concat(temps, ',')
            local s = redis.call('HMGET', KEYS[2], 'count', 'temp_sum', 'min_temp', 'max_temp', 'anomaly_count')
            result[2] = s[1] or '0'
            result[3] = s[2] or '0'
            result[4] = s[3] or '0'
            result[5] = s[4] or '0'
            result[6] = s[5] or '0'
            local anoms = redis.call('ZRANGEBYSCORE', KEYS[3], ARGV[1], ARGV[2])
            result[7] = table.concat(anoms, ',')
            return result
            """)

        self.synthesisScript = client.script("""
            local result = {}
            local s = redis.call('HMGET', KEYS[1], 'count', 'temp_sum', 'min_temp', 'max_temp', 'anomaly_count')
            result[1] = s[1] or '0'
            result[2] = s[2] or '0'
            result[3] = s[3] or '0'
            result[4] = s[4] or '0'
            result[5] = s[5] or '0'
            local anoms = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', '+inf')
            result[6] = table.concat(anoms, ',')
            local decs = redis.call('LRANGE', KEYS[3], 0, -1)
            result[7] = table.concat(decs, '|')
            return result
            """)
    }

    func flush() {
        _ = try? readings.deleteKey()
        _ = try? stats.deleteKey()
        _ = try? anomalies.deleteKey()
        _ = try? decisions.deleteKey()
        for i in 0...9 { _ = try? dazzle.hash("agent:checkpoint:\(i)").deleteKey() }
    }

    // MARK: - Ingest (standard typed primitives)

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
    }

    // MARK: - Context block (1 Lua EVAL = 1 round-trip)

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        let windowStart = max(0, currentMinute - windowMinutes)
        guard let reply = try? contextBlockScript.eval(
            keys: ["sensor:readings", "sensor:stats", "sensor:anomalies"],
            args: [String(windowStart), String(currentMinute), String(windowMinutes)]
        ) else { return "" }

        let raw = reply.asArray.map { $0.asBulkOrNil ?? "" }
        var lines: [String] = []

        // raw[0] = temps CSV
        let tempsCsv = raw.first ?? ""
        if !tempsCsv.isEmpty {
            let temps = tempsCsv.split(separator: ",").compactMap { Double($0) }
            if !temps.isEmpty {
                let formatted = temps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                lines.append("Last \(temps.count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(formatted)")
                lines.append("Recent trend: \(computeTrend(temps))")
            }
        }

        // raw[1..5] = count/sum/min/max/anomCnt
        if let count = Int(raw.count > 1 ? raw[1] : "0"), count > 0 {
            let sum  = Double(raw.count > 2 ? raw[2] : "0") ?? 0
            let minT = Double(raw.count > 3 ? raw[3] : "0") ?? 0
            let maxT = Double(raw.count > 4 ? raw[4] : "0") ?? 0
            let anomCnt = Int(raw.count > 5 ? raw[5] : "0") ?? 0
            lines.append("Aggregate over \(count) readings: " +
                "avg=\(String(format: "%.1f", sum / Double(count)))\u{00B0}C, " +
                "min=\(String(format: "%.1f", minT))\u{00B0}C, " +
                "max=\(String(format: "%.1f", maxT))\u{00B0}C")
            lines.append("Total anomalies detected so far: \(anomCnt)")
        }

        // raw[6] = anomaly mins CSV
        let anomsCsv = raw.count > 6 ? raw[6] : ""
        if anomsCsv.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(anomsCsv)]")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        guard let reply = try? synthesisScript.eval(
            keys: ["sensor:stats", "sensor:anomalies", "agent:decisions"],
            args: []
        ) else { return "" }

        let raw = reply.asArray.map { $0.asBulkOrNil ?? "" }
        var lines: [String] = []

        // raw[0..4] = count/sum/min/max/anomCnt
        if let count = Int(raw.count > 0 ? raw[0] : "0"), count > 0 {
            let sum  = Double(raw.count > 1 ? raw[1] : "0") ?? 0
            let minT = Double(raw.count > 2 ? raw[2] : "0") ?? 0
            let maxT = Double(raw.count > 3 ? raw[3] : "0") ?? 0
            let anomCnt = Int(raw.count > 4 ? raw[4] : "0") ?? 0
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(count)")
            lines.append("Temperature range: \(String(format: "%.1f", minT))\u{00B0}C to " +
                "\(String(format: "%.1f", maxT))\u{00B0}C " +
                "(avg \(String(format: "%.1f", sum / Double(count)))\u{00B0}C)")
            lines.append("Total anomalies detected: \(anomCnt)")
        }

        // raw[5] = anomaly mins CSV
        let anomsCsv = raw.count > 5 ? raw[5] : ""
        if !anomsCsv.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): [\(anomsCsv)]")
        }

        // raw[6] = decisions pipe-separated
        let decsPipe = raw.count > 6 ? raw[6] : ""
        if !decsPipe.isEmpty {
            let decs = decsPipe.split(separator: "|").map(String.init)
            lines.append("=== Monitoring Agent Decisions ===")
            for (idx, decision) in decs.enumerated() {
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
