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

import Foundation

/// Incremental-context backend — materialized view pattern, all state in Valkey.
///
/// Mirrors DazzleIncrementalIoTManager.kt exactly.
///
/// A single Lua script runs on every ingest():
///   stream-append + stats + server-side min/max + rolling-temps list (LPUSH/LTRIM) +
///   OLS trend + window-anomalies + derived HSET — one EVALSHA crossing, no Swift state.
///
/// buildContextBlock() = one mGetDirect (same as DazzlePrecompute) but with no
/// NSLock needed: all mutable data lives inside Valkey's C-level mutex.
final class DazzleIncrementalIoTManager: StorageBackend {

    let backendName: String = "Dazzle-Incremental"

    private let dazzle:    Dazzle
    private let stats:     HashKey
    private let anomalies: SortedSetKey
    private let decisions: ListKey

    // Lua ingest script — same logic as the Kotlin version, line-for-line.
    // KEYS: [1]=sensor:readings  [2]=sensor:stats
    //       [3]=sensor:temps_recent  [4]=sensor:anomalies
    // ARGV: [1]=tempC  [2]=humidity  [3]=minute  [4]=anomalous(1/0)  [5]=windowMinutes
    private let ingestScript: LuaScript

    init() {
        let client = DazzleServer.shared.client()
        self.dazzle    = client
        self.stats     = client.hash("sensor:stats")
        self.anomalies = client.sortedSet("sensor:anomalies")
        self.decisions = client.list("agent:decisions")
        self.ingestScript = client.script("""
            local temp    = tonumber(ARGV[1])
            local minute  = tonumber(ARGV[3])
            local win_min = tonumber(ARGV[5]) or 20

            redis.call('XADD', KEYS[1], 'MAXLEN', '~', '200', '*',
                'temp', ARGV[1], 'humidity', ARGV[2],
                'minute', ARGV[3], 'anomalous', ARGV[4])

            redis.call('HINCRBYFLOAT', KEYS[2], 'temp_sum', ARGV[1])
            redis.call('HINCRBY',      KEYS[2], 'count', 1)
            redis.call('HSET', KEYS[2], 'latest_temp', ARGV[1], 'latest_minute', ARGV[3])

            local cur_min = tonumber(redis.call('HGET', KEYS[2], 'min_temp'))
            if not cur_min or temp < cur_min then
                redis.call('HSET', KEYS[2], 'min_temp', ARGV[1])
            end
            local cur_max = tonumber(redis.call('HGET', KEYS[2], 'max_temp'))
            if not cur_max or temp > cur_max then
                redis.call('HSET', KEYS[2], 'max_temp', ARGV[1])
            end

            if ARGV[4] == '1' then
                redis.call('ZADD', KEYS[4], minute, ARGV[3])
                redis.call('HINCRBY', KEYS[2], 'anomaly_count', 1)
            end

            redis.call('LPUSH', KEYS[3], ARGV[1])
            redis.call('LTRIM', KEYS[3], 0, 9)

            local raw = redis.call('LRANGE', KEYS[3], 0, -1)
            local n   = #raw
            local slope = 0.0
            if n >= 2 then
                local sx, sy, sxy, sxx = 0.0, 0.0, 0.0, 0.0
                for i = 1, n do
                    local x = n - i
                    local y = tonumber(raw[i])
                    sx  = sx  + x
                    sy  = sy  + y
                    sxy = sxy + x * y
                    sxx = sxx + x * x
                end
                local denom = n * sxx - sx * sx
                if denom ~= 0 then slope = (n * sxy - sx * sy) / denom end
            end
            local trend = 'stable'
            if     slope >  0.15 then trend = 'increasing'
            elseif slope < -0.15 then trend = 'decreasing'
            end

            local parts = {}
            for i = n, 1, -1 do
                parts[n - i + 1] = string.format('%.1f', tonumber(raw[i]))
            end
            local temps_csv = table.concat(parts, ',')

            local win_start = math.max(0, minute - win_min)
            local win_anoms = redis.call('ZRANGEBYSCORE', KEYS[4], win_start, minute)
            local anoms_csv = table.concat(win_anoms, ',')

            redis.call('HSET', KEYS[2],
                'recent_temps_csv',     temps_csv,
                'recent_trend',         trend,
                'window_anomalies_csv', anoms_csv,
                'window_minutes',       tostring(win_min))
            return 1
        """)
    }

    // MARK: - Lifecycle

    func flush() {
        _ = try? dazzle.stream("sensor:readings").deleteKey()
        _ = try? stats.deleteKey()
        _ = try? anomalies.deleteKey()
        _ = try? decisions.deleteKey()
        _ = try? dazzle.list("sensor:temps_recent").deleteKey()
        for i in 0...9 { _ = try? dazzle.hash("agent:checkpoint:\(i)").deleteKey() }
    }

    // MARK: - Ingest: 1 EVALSHA, no Swift lock

    func ingest(_ reading: SensorReading) {
        _ = try? ingestScript.eval(
            keys: ["sensor:readings", "sensor:stats", "sensor:temps_recent", "sensor:anomalies"],
            args: [
                String(reading.tempC),
                String(reading.humidity),
                String(reading.minute),
                reading.anomalous ? "1" : "0",
                "20",
            ]
        )
    }

    // MARK: - Context block: 1 mGetDirect, concurrent-safe

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        // mGetDirect throws and returns [String?]. Flatten into a fixed-length
        // [String] (empty string for missing/nil) so the safe-subscript helper
        // below doesn't produce String?? double-optionals.
        let raw = (try? stats.mGetDirect(
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count",
            "recent_temps_csv", "recent_trend", "window_anomalies_csv"
        )) ?? []
        let fields: [String] = (0..<8).map { i in
            (i < raw.count ? raw[i] : nil) ?? ""
        }

        var lines: [String] = []

        let tempsCsv = fields[5]
        if !tempsCsv.isEmpty {
            let n = tempsCsv.components(separatedBy: ",").count
            lines.append("Last \(n) temperatures (oldest→newest, °C): \(tempsCsv)")
            let trend = fields[6].isEmpty ? "stable" : fields[6]
            lines.append("Recent trend: \(trend)")
        }

        if let count = Int(fields[0]), count > 0 {
            let sum     = Double(fields[1]) ?? 0
            let minT    = Double(fields[2]) ?? 0
            let maxT    = Double(fields[3]) ?? 0
            let anomCnt = Int(fields[4]) ?? 0
            lines.append(String(format:
                "Aggregate over %d readings: avg=%.1f°C, min=%.1f°C, max=%.1f°C",
                count, sum / Double(count), minT, maxT))
            lines.append("Total anomalies detected so far: \(anomCnt)")
        }

        let anomsCsv = fields[7]
        if anomsCsv.isEmpty {
            lines.append("No anomalies in the last 20 minutes.")
        } else {
            lines.append("Anomalous time indices in the last 20 minutes " +
                "(minute numbers, not temperatures): [\(anomsCsv)]")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        var lines: [String] = []

        let raw = (try? stats.mGetDirect("count", "temp_sum", "min_temp", "max_temp", "anomaly_count")) ?? []
        let fields: [String] = (0..<5).map { i in (i < raw.count ? raw[i] : nil) ?? "" }
        if let count = Int(fields[0]), count > 0 {
            let sum     = Double(fields[1]) ?? 0
            let minT    = Double(fields[2]) ?? 0
            let maxT    = Double(fields[3]) ?? 0
            let anomCnt = Int(fields[4]) ?? 0
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(count)")
            lines.append(String(format:
                "Temperature range: %.1f°C to %.1f°C (avg %.1f°C)", minT, maxT, sum / Double(count)))
            lines.append("Total anomalies detected: \(anomCnt)")
        }

        let allAnoms = (try? anomalies.rangeByScore(min: 0, max: 99999)) ?? []
        if !allAnoms.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): [\(allAnoms.joined(separator: ", "))]")
        }

        let decs = (try? decisions.range(0, -1)) ?? []
        if !decs.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (i, d) in decs.enumerated() { lines.append("  Checkpoint \(i + 1): \(d)") }
        }

        return lines.joined(separator: "\n")
    }

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool,
                                  severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"
        _ = DazzleServer.shared.directPipelineArgs([
            ["HSET", "agent:checkpoint:\(index)",
             "minute", String(minute), "anomaly", anomalyDetected ? "1" : "0",
             "severity", severity, "trend", trend],
            ["RPUSH", "agent:decisions", decision],
        ])
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

// Safe subscript for optional array access
private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
