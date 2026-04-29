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
// DazzleServer / Valkey / primitives are compiled directly into the target
// (see project.yml sources).

// ─────────────────────────────────────────────────────────────────────────────
// DazzleContextManager
//
// Sensor-specific view of the embedded Valkey instance, built on top of the
// type-safe primitive API (StreamKey / HashKey / SortedSetKey / ListKey).
// No direct `directCommand("XADD ...")` strings anywhere — everything is
// one method call per operation, mirroring the Android ValkeyContextManager
// byte-for-byte so both platforms feed Gemma identical prompts.
//
// Data layout:
//   sensor:readings        Stream      MAXLEN ~ 200   full reading history
//   sensor:stats           Hash                       running aggregates
//   sensor:anomalies       SortedSet   score = minute confirmed anomaly minutes
//   agent:decisions        List                       per-checkpoint decisions
//   agent:checkpoint:{N}   Hash                       per-checkpoint analysis
// ─────────────────────────────────────────────────────────────────────────────

struct SensorReading {
    let minute: Int
    let tempC:  Double
    let humidity: Double
    let anomalous: Bool
}

struct RunningStats {
    let count:        Int
    let avgTemp:      Double
    let minTemp:      Double
    let maxTemp:      Double
    let anomalyCount: Int
}

final class DazzleContextManager: StorageBackend {

    let backendName: String = "Dazzle"

    private let dazzle: Dazzle
    private let readings: StreamKey
    private let stats: HashKey
    private let anomalies: SortedSetKey
    private let decisions: ListKey

    init() {
        let client = DazzleServer.shared.client()
        self.dazzle = client
        self.readings  = client.stream("sensor:readings")
        self.stats     = client.hash("sensor:stats")
        self.anomalies = client.sortedSet("sensor:anomalies")
        self.decisions = client.list("agent:decisions")
    }

    // MARK: - Lifecycle

    func flush() {
        _ = try? readings.deleteKey()
        _ = try? stats.deleteKey()
        _ = try? anomalies.deleteKey()
        _ = try? decisions.deleteKey()
        for i in 0...9 {
            _ = try? dazzle.hash("agent:checkpoint:\(i)").deleteKey()
        }
    }

    // MARK: - Ingestion

    func ingest(_ reading: SensorReading) {
        // Bounded stream — Valkey handles the MAXLEN trim for us
        _ = try? readings.add(
            fields: [
                ("temp",      String(reading.tempC)),
                ("humidity",  String(reading.humidity)),
                ("minute",    String(reading.minute)),
                ("anomalous", reading.anomalous ? "1" : "0"),
            ],
            maxLen: 200
        )

        // Running aggregates — atomic hash ops
        _ = try? stats.incrByFloat("temp_sum", reading.tempC)
        _ = try? stats.incrBy("count", 1)
        _ = try? stats.set("latest_temp", String(reading.tempC))
        _ = try? stats.set("latest_minute", String(reading.minute))

        // Min / max — read-modify-write (OK because single-writer)
        let curMin = (try? stats.get("min_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMin == nil || reading.tempC < curMin! {
            _ = try? stats.set("min_temp", String(reading.tempC))
        }
        let curMax = (try? stats.get("max_temp")).flatMap { $0 }.flatMap { Double($0) }
        if curMax == nil || reading.tempC > curMax! {
            _ = try? stats.set("max_temp", String(reading.tempC))
        }

        // Anomaly tracking
        if reading.anomalous {
            _ = try? anomalies.add(score: Double(reading.minute), member: String(reading.minute))
            _ = try? stats.incrBy("anomaly_count", 1)
        }
    }

    // MARK: - Context retrieval

    /// Build a natural-language context block for prompt injection.
    /// See the Android counterpart in ValkeyContextManager.kt for the
    /// rationale of typing integer minute indices in the output.
    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        var lines: [String] = []

        // Last 10 readings from the stream (oldest → newest)
        if let entries = try? readings.revRange(count: 10) {
            let temps = entries
                .compactMap { entry in
                    entry.fields.first(where: { $0.0 == "temp" }).flatMap { Double($0.1) }
                }
                .reversed()
            let tempsArr = Array(temps)
            if !tempsArr.isEmpty {
                let formatted = tempsArr.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                lines.append("Last \(tempsArr.count) temperatures (oldest→newest, °C): \(formatted)")
                lines.append("Recent trend: \(computeTrend(tempsArr))")
            }
        }

        // Aggregate statistics (snapshot-cache HMGET — no pipe)
        if let s = readStats() {
            lines.append("Aggregate over \(s.count) readings: " +
                "avg=\(String(format: "%.1f", s.avgTemp))°C, " +
                "min=\(String(format: "%.1f", s.minTemp))°C, " +
                "max=\(String(format: "%.1f", s.maxTemp))°C")
            lines.append("Total anomalies detected so far: \(s.anomalyCount)")
        }

        // Anomalies in the current window (time indices, not temperatures)
        let windowStart = max(0, currentMinute - windowMinutes)
        let windowAnomalies = (try? anomalies.rangeByScore(
            min: Double(windowStart), max: Double(currentMinute)
        )) ?? []
        if windowAnomalies.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(windowAnomalies.joined(separator: ", "))]")
        }

        return lines.joined(separator: "\n")
    }

    /// Build a full history block for the CP10 synthesis.
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

        let allAnomalyMins = (try? anomalies.rangeByScore(min: 0, max: 99999)) ?? []
        if !allAnomalyMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                "[\(allAnomalyMins.joined(separator: ", "))]")
        }

        // Per-checkpoint decisions — minute index intentionally omitted
        // from each line (see buildContextBlock doc for the hallucination
        // failure mode this avoids).
        let decisionLines = (try? decisions.range(0, -1)) ?? []
        if !decisionLines.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (idx, decision) in decisionLines.enumerated() {
                lines.append("  Checkpoint \(idx + 1): \(decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Decision storage (Condition B only)

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decisionText = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"

        _ = try? dazzle.hash("agent:checkpoint:\(index)").setAll([
            "minute":   String(minute),
            "anomaly":  anomalyDetected ? "1" : "0",
            "severity": severity,
            "trend":    trend,
        ])
        _ = try? decisions.rpush(decisionText)
    }

    // MARK: - Retrieval latency measurement

    func measureRetrievalLatency(currentMinute: Int) -> Double {
        let start = DispatchTime.now()
        _ = buildContextBlock(currentMinute: currentMinute)
        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000.0  // µs
    }

    // MARK: - Private helpers

    private func readStats() -> RunningStats? {
        // Phase 1 direct-read — 1 snapshot-cache lookup (zero pipe, zero
        // event loop) instead of 5 HGETs. Falls back to HMGET over the pipe
        // on cache miss so semantics match the original code.
        let values: [String?]
        do {
            values = try stats.mGetDirect("count", "temp_sum", "min_temp", "max_temp", "anomaly_count")
        } catch {
            return nil
        }
        guard values.count == 5,
              let countStr = values[0], let countVal = Int(countStr), countVal > 0 else {
            return nil
        }
        let sum     = values[1].flatMap { Double($0) } ?? 0
        let minTemp = values[2].flatMap { Double($0) } ?? 0
        let maxTemp = values[3].flatMap { Double($0) } ?? 0
        let anomCnt = values[4].flatMap { Int($0) } ?? 0
        return RunningStats(
            count: countVal,
            avgTemp: sum / Double(countVal),
            minTemp: minTemp,
            maxTemp: maxTemp,
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
