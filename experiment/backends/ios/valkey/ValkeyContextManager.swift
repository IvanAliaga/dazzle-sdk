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

/// Stock-Valkey baseline that speaks RESP2 over TCP loopback.
///
/// Companion to `DazzleContextManager`: same data layout, same commands,
/// but the transport is a real TCP socket to `127.0.0.1:<port>` — the
/// path any app using a Jedis/Lettuce-style Valkey client would take
/// today. The server it talks to is still the same embedded Dazzle
/// build, so command semantics match byte-for-byte; the only variable
/// across runs is the transport.
///
///   Dazzle : app thread → self-pipe → server ae loop
///   Valkey : app thread → kernel TCP → kqueue → server ae loop
///
/// Uses one persistent socket protected by an NSLock so it mirrors the
/// cost model a real mobile client would have (no ephemeral-port churn).
final class ValkeyContextManager: StorageBackend {

    let backendName: String = "Valkey"

    private var input:  InputStream!
    private var output: OutputStream!
    private let lock = NSLock()

    // Pre-allocated 64 KB read buffer, grown on demand by `readBytes`.
    private var readBuf = [UInt8](repeating: 0, count: 64 * 1024)

    init(host: String = "127.0.0.1", port: Int = DazzleServer.shared.port) {
        var is_: InputStream?
        var os_: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &is_, outputStream: &os_)
        guard let i = is_, let o = os_ else {
            fatalError("ValkeyContextManager: could not open TCP socket to \(host):\(port)")
        }
        i.open(); o.open()
        self.input = i
        self.output = o
    }

    // ── RESP encode ──────────────────────────────────────────────────────

    @discardableResult
    private func send(_ args: String...) -> Reply {
        lock.lock(); defer { lock.unlock() }
        var payload = "*\(args.count)\r\n"
        for a in args {
            let bytes = a.utf8.count
            payload += "$\(bytes)\r\n\(a)\r\n"
        }
        let data = Array(payload.utf8)
        _ = data.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: data.count) }
        return readReply()
    }

    // ── RESP decode ──────────────────────────────────────────────────────

    private func readReply() -> Reply {
        let marker = readByte()
        switch marker {
        case UInt8(ascii: "+"): return .simple(readLine())
        case UInt8(ascii: "-"): return .error(readLine())
        case UInt8(ascii: ":"): return .integer(Int64(readLine()) ?? 0)
        case UInt8(ascii: "$"):
            let n = Int(readLine()) ?? -1
            if n < 0 { return .bulk(nil) }
            let s = readExact(n)
            _ = readByte(); _ = readByte()   // CRLF
            return .bulk(s)
        case UInt8(ascii: "*"):
            let n = Int(readLine()) ?? -1
            if n < 0 { return .array(nil) }
            var items: [Reply] = []
            items.reserveCapacity(n)
            for _ in 0..<n { items.append(readReply()) }
            return .array(items)
        default:
            return .error("bad RESP marker \(marker)")
        }
    }

    private func readByte() -> UInt8 {
        var byte: UInt8 = 0
        let n = withUnsafeMutablePointer(to: &byte) { input.read($0, maxLength: 1) }
        precondition(n == 1, "socket EOF")
        return byte
    }

    private func readLine() -> String {
        var out: [UInt8] = []
        while true {
            let b = readByte()
            if b == 0x0D { _ = readByte(); return String(bytes: out, encoding: .utf8) ?? "" }
            out.append(b)
        }
    }

    private func readExact(_ count: Int) -> String {
        if count > readBuf.count { readBuf = [UInt8](repeating: 0, count: count) }
        var off = 0
        while off < count {
            let r = readBuf.withUnsafeMutableBufferPointer { input.read($0.baseAddress! + off, maxLength: count - off) }
            precondition(r > 0, "socket EOF")
            off += r
        }
        return String(bytes: readBuf[0..<count], encoding: .utf8) ?? ""
    }

    private enum Reply {
        case simple(String)
        case error(String)
        case integer(Int64)
        case bulk(String?)
        case array([Reply]?)

        var bulkOrNil: String? {
            switch self {
            case .bulk(let v):   return v
            case .simple(let v): return v
            case .integer(let v): return String(v)
            default:              return nil
            }
        }
        var arrayOfBulks: [String?] {
            if case .array(let items) = self { return (items ?? []).map { $0.bulkOrNil } }
            return []
        }
    }

    // ── StorageBackend ────────────────────────────────────────────────────

    func flush() {
        _ = send("DEL", "sensor:readings", "sensor:stats", "sensor:anomalies", "agent:decisions")
        for i in 0...9 { _ = send("DEL", "agent:checkpoint:\(i)") }
    }

    func ingest(_ reading: SensorReading) {
        _ = send(
            "XADD", "sensor:readings", "MAXLEN", "~", "200", "*",
            "temp",      String(reading.tempC),
            "humidity",  String(reading.humidity),
            "minute",    String(reading.minute),
            "anomalous", reading.anomalous ? "1" : "0"
        )
        _ = send("HINCRBYFLOAT", "sensor:stats", "temp_sum", String(reading.tempC))
        _ = send("HINCRBY",      "sensor:stats", "count",    "1")
        _ = send("HSET", "sensor:stats",
                 "latest_temp",   String(reading.tempC),
                 "latest_minute", String(reading.minute))

        if let curMin = send("HGET", "sensor:stats", "min_temp").bulkOrNil.flatMap(Double.init) {
            if reading.tempC < curMin {
                _ = send("HSET", "sensor:stats", "min_temp", String(reading.tempC))
            }
        } else {
            _ = send("HSET", "sensor:stats", "min_temp", String(reading.tempC))
        }
        if let curMax = send("HGET", "sensor:stats", "max_temp").bulkOrNil.flatMap(Double.init) {
            if reading.tempC > curMax {
                _ = send("HSET", "sensor:stats", "max_temp", String(reading.tempC))
            }
        } else {
            _ = send("HSET", "sensor:stats", "max_temp", String(reading.tempC))
        }

        if reading.anomalous {
            _ = send("ZADD", "sensor:anomalies",
                     String(reading.minute), String(reading.minute))
            _ = send("HINCRBY", "sensor:stats", "anomaly_count", "1")
        }
    }

    func buildContextBlock(currentMinute: Int, windowMinutes: Int) -> String {
        var lines: [String] = []

        // Last 10 entries — newest first
        var temps: [Double] = []
        if case .array(let items) = send("XREVRANGE", "sensor:readings", "+", "-", "COUNT", "10") {
            for entry in items ?? [] {
                guard case .array(let pair?) = entry, pair.count >= 2 else { continue }
                guard case .array(let fields?) = pair[1] else { continue }
                var i = 0
                while i < fields.count - 1 {
                    if case .bulk(let k?) = fields[i], k == "temp" {
                        if case .bulk(let v?) = fields[i + 1], let t = Double(v) { temps.append(t) }
                        break
                    }
                    i += 2
                }
            }
        }
        let recentTemps = Array(temps.reversed())
        if !recentTemps.isEmpty {
            let formatted = recentTemps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            lines.append("Last \(recentTemps.count) temperatures (oldest→newest, °C): \(formatted)")
            lines.append("Recent trend: \(computeTrend(recentTemps))")
        }

        let vals = send(
            "HMGET", "sensor:stats",
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count"
        ).arrayOfBulks
        if vals.count == 5, let count = vals[0].flatMap(Int.init), count > 0 {
            let sum    = vals[1].flatMap(Double.init) ?? 0
            let minT   = vals[2].flatMap(Double.init) ?? 0
            let maxT   = vals[3].flatMap(Double.init) ?? 0
            let anomCt = vals[4].flatMap(Int.init) ?? 0
            lines.append("Aggregate over \(count) readings: " +
                "avg=\(String(format: "%.1f", sum / Double(count)))°C, " +
                "min=\(String(format: "%.1f", minT))°C, " +
                "max=\(String(format: "%.1f", maxT))°C")
            lines.append("Total anomalies detected so far: \(anomCt)")
        }

        let windowStart = max(0, currentMinute - windowMinutes)
        let anomaliesInWindow = send(
            "ZRANGEBYSCORE", "sensor:anomalies",
            String(windowStart), String(currentMinute)
        ).arrayOfBulks.compactMap { $0 }
        if anomaliesInWindow.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(anomaliesInWindow.joined(separator: ", "))]")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        var lines: [String] = []
        let vals = send(
            "HMGET", "sensor:stats",
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count"
        ).arrayOfBulks
        if vals.count == 5, let count = vals[0].flatMap(Int.init), count > 0 {
            let sum    = vals[1].flatMap(Double.init) ?? 0
            let minT   = vals[2].flatMap(Double.init) ?? 0
            let maxT   = vals[3].flatMap(Double.init) ?? 0
            let anomCt = vals[4].flatMap(Int.init) ?? 0
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(count)")
            lines.append("Temperature range: \(String(format: "%.1f", minT))°C to " +
                "\(String(format: "%.1f", maxT))°C " +
                "(avg \(String(format: "%.1f", sum / Double(count)))°C)")
            lines.append("Total anomalies detected: \(anomCt)")
        }

        let allAnomalies = send(
            "ZRANGEBYSCORE", "sensor:anomalies", "0", "99999"
        ).arrayOfBulks.compactMap { $0 }
        if !allAnomalies.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                "[\(allAnomalies.joined(separator: ", "))]")
        }

        let decisions = send("LRANGE", "agent:decisions", "0", "-1").arrayOfBulks.compactMap { $0 }
        if !decisions.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for (i, d) in decisions.enumerated() {
                lines.append("  Checkpoint \(i + 1): \(d)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func storeCheckpointDecision(
        index: Int, minute: Int,
        anomalyDetected: Bool, severity: String, trend: String
    ) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"
        _ = send(
            "HSET", "agent:checkpoint:\(index)",
            "minute",   String(minute),
            "anomaly",  anomalyDetected ? "1" : "0",
            "severity", severity,
            "trend",    trend
        )
        _ = send("RPUSH", "agent:decisions", decision)
    }

    func measureRetrievalLatency(currentMinute: Int) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = buildContextBlock(currentMinute: currentMinute, windowMinutes: 20)
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000.0
    }

    private func computeTrend(_ temps: [Double]) -> String {
        guard temps.count >= 2 else { return "stable" }
        let n = temps.count
        let meanX = Double(n - 1) / 2.0
        let meanY = temps.reduce(0.0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0..<n {
            let dx = Double(i) - meanX
            num += dx * (temps[i] - meanY)
            den += dx * dx
        }
        let slope = den != 0 ? num / den : 0
        if slope >  0.15 { return "increasing" }
        if slope < -0.15 { return "decreasing" }
        return "stable"
    }

    // ── Footprint accounting ──────────────────────────────────────────────
    //
    // We talk RESP over the same TCP socket every other command uses, so
    // the byte count we report is what a real Lettuce/Jedis-style mobile
    // client would observe — no in-process shortcut.

    var backendSizeMethod: String { "valkey:used_memory_dataset" }

    func backendSizeBytes() -> Int64 {
        guard let raw = send("INFO", "memory").bulkOrNil else { return -1 }
        return parseValkeyUsedMemoryDataset(raw)
    }

    func backendSizeBreakdown() -> [String: Int64]? {
        guard let raw = send("INFO", "memory").bulkOrNil else { return nil }
        return parseValkeyMemoryStats(raw)
    }
}
