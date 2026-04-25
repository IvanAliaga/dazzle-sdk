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

import SwiftUI
import Foundation
import SQLite3

struct BenchmarkView: View {
    @State private var isRunning = false
    @State private var isBenchmarking = false
    @State private var output = ""
    @State private var results = ""

    private let server = DazzleServer.shared

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(isRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(isRunning ? "Dazzle Running" : "Dazzle Stopped")
                        .font(.subheadline)
                    Spacer()
                    if !isRunning {
                        Button("Start Server") { startServer() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                Button(action: runAllBenchmarks) {
                    HStack {
                        if isBenchmarking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isBenchmarking ? "Running..." : "Run All Benchmarks")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isRunning || isBenchmarking)

                ScrollView {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)

                if !results.isEmpty {
                    Button("Copy Results") {
                        UIPasteboard.general.string = results
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Benchmarks")
        }
        .onAppear { checkAndRunTrigger() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { checkAndRunTrigger() }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    private func checkAndRunTrigger() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let trigger = docs.appendingPathComponent("run_mem_bench")
        guard FileManager.default.fileExists(atPath: trigger.path) else { return }
        try? FileManager.default.removeItem(at: trigger)
        autoRunMemoryBenchmark()
    }

    private func autoRunMemoryBenchmark() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = server.start()
            guard ok, server.waitForReady(timeout: 10) else { return }
            DispatchQueue.main.async { isRunning = true }
            let md = benchMemory()
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? md.write(to: docs.appendingPathComponent("mem_bench_result.txt"),
                          atomically: true, encoding: .utf8)
        }
    }

    private func startServer() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = server.start()
            DispatchQueue.main.async {
                isRunning = server.isRunning
                if ok {
                    appendOutput("Server started on port \(server.port)")
                } else {
                    appendOutput("ERROR: Failed to start server")
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        output += text + "\n"
    }

    private func runAllBenchmarks() {
        output = ""
        results = ""
        isBenchmarking = true

        DispatchQueue.global(qos: .userInitiated).async {
            var md = "# Benchmark Results: iOS\n\n"
            md += deviceInfo()

            log("=== Starting Benchmark Suite ===\n")

            // Flush any data loaded from AOF at startup, then capture the true empty
            // baseline before any benchmark adds keys or grows hash tables.
            cmd("FLUSHALL")
            let freshMemInfo = cmd("INFO memory")

            // 1. SET/GET Latency
            md += benchSetGetLatency()

            // 2. SET/GET Throughput
            md += benchSetGetThroughput()

            // 3. XADD Throughput
            md += benchXaddThroughput()

            // 4. GEOSEARCH Latency
            md += benchGeosearch()

            // 5. Persistence
            md += benchPersistence()

            // 6. Memory — pass the fresh-server snapshot as the empty baseline
            md += benchMemory(freshMemInfo: freshMemInfo)

            // 7. SQLite WAL comparison (same device, same number of ops)
            md += benchSQLite()

            // 8. Direct in-process vs TCP latency comparison
            md += benchDirect()

            // 9. Battery / CPU overhead
            md += benchBattery()

            log("\n=== Benchmarks Complete ===")

            // Print full results to console for capture via xcrun simctl
            print("===BENCHMARK_RESULTS_START===")
            print(md)
            print("===BENCHMARK_RESULTS_END===")

            DispatchQueue.main.async {
                self.results = md
                self.isBenchmarking = false
            }
        }
    }

    // MARK: - Device Info

    private func deviceInfo() -> String {
        var info = "| Field | Value |\n|-------|-------|\n"
        info += "| **Device** | \(deviceModel()) |\n"
        info += "| **OS** | iOS \(UIDevice.current.systemVersion) |\n"
        info += "| **Arch** | \(cpuArch()) |\n"
        info += "| **RAM** | \(totalRAM())MB |\n"
        info += "| **Date** | \(ISO8601DateFormatter().string(from: Date())) |\n\n"
        log("Device: \(deviceModel()), iOS \(UIDevice.current.systemVersion), \(totalRAM())MB RAM")
        return info
    }

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func cpuArch() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private func totalRAM() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
    }

    // MARK: - Helpers

    private func log(_ msg: String) {
        DispatchQueue.main.async { self.appendOutput(msg) }
    }

    @discardableResult
    private func cmd(_ command: String) -> String {
        server.command(command) ?? "nil"
    }

    private func measureLatency(iterations: Int, command: @autoclosure () -> String) -> (avgMs: Double, minMs: Double, maxMs: Double, p50Ms: Double, p95Ms: Double, p99Ms: Double) {
        var latencies = [Double]()
        latencies.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = cmd(command())
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            latencies.append(elapsed)
        }

        latencies.sort()
        let avg = latencies.reduce(0, +) / Double(latencies.count)
        let minVal = latencies.first ?? 0
        let maxVal = latencies.last ?? 0
        let p50 = latencies[Int(Double(latencies.count) * 0.50)]
        let p95 = latencies[Int(Double(latencies.count) * 0.95)]
        let p99idx = Swift.min(Int(Double(latencies.count) * 0.99), latencies.count - 1)
        let p99 = latencies[p99idx]

        return (avg, minVal, maxVal, p50, p95, p99)
    }

    // MARK: - Benchmarks

    private func benchSetGetLatency() -> String {
        log("\n--- 1. SET/GET Latency (single op) ---")
        var md = "## 1. SET/GET Latency (single operation, 10K iterations)\n\n"

        // Warmup
        for i in 0..<100 { cmd("SET warmup:\(i) value\(i)") }
        cmd("FLUSHDB")

        let setResult = measureLatency(iterations: 10000, command: "SET bench:key:\(Int.random(in: 0..<10000)) value_data_128bytes_padding_to_simulate_real_world_payload_size_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        log("SET: avg=\(String(format: "%.3f", setResult.avgMs))ms p50=\(String(format: "%.3f", setResult.p50Ms))ms p95=\(String(format: "%.3f", setResult.p95Ms))ms p99=\(String(format: "%.3f", setResult.p99Ms))ms")

        let getResult = measureLatency(iterations: 10000, command: "GET bench:key:\(Int.random(in: 0..<10000))")
        log("GET: avg=\(String(format: "%.3f", getResult.avgMs))ms p50=\(String(format: "%.3f", getResult.p50Ms))ms p95=\(String(format: "%.3f", getResult.p95Ms))ms p99=\(String(format: "%.3f", getResult.p99Ms))ms")

        md += "| Command | Avg (ms) | Min (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) |\n"
        md += "|---------|----------|----------|----------|----------|----------|----------|\n"
        md += "| SET | \(f(setResult.avgMs)) | \(f(setResult.minMs)) | \(f(setResult.p50Ms)) | \(f(setResult.p95Ms)) | \(f(setResult.p99Ms)) | \(f(setResult.maxMs)) |\n"
        md += "| GET | \(f(getResult.avgMs)) | \(f(getResult.minMs)) | \(f(getResult.p50Ms)) | \(f(getResult.p95Ms)) | \(f(getResult.p99Ms)) | \(f(getResult.maxMs)) |\n\n"

        cmd("FLUSHDB")
        return md
    }

    private func benchSetGetThroughput() -> String {
        log("\n--- 2. SET/GET Throughput ---")
        var md = "## 2. SET/GET Throughput\n\n"
        md += "| Operations | SET (ops/sec) | SET time (ms) | GET (ops/sec) | GET time (ms) |\n"
        md += "|------------|---------------|---------------|---------------|---------------|\n"

        for count in [1000, 5000, 10000] {
            // SET throughput
            let setStart = CFAbsoluteTimeGetCurrent()
            for i in 0..<count {
                cmd("SET bench:tp:\(i) value_\(i)_padding_for_128_bytes_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
            }
            let setTime = (CFAbsoluteTimeGetCurrent() - setStart) * 1000.0
            let setRps = Double(count) / (setTime / 1000.0)

            // GET throughput
            let getStart = CFAbsoluteTimeGetCurrent()
            for i in 0..<count {
                cmd("GET bench:tp:\(i)")
            }
            let getTime = (CFAbsoluteTimeGetCurrent() - getStart) * 1000.0
            let getRps = Double(count) / (getTime / 1000.0)

            log("\(count) ops: SET=\(Int(setRps)) ops/s (\(Int(setTime))ms), GET=\(Int(getRps)) ops/s (\(Int(getTime))ms)")
            md += "| \(count) | \(Int(setRps)) | \(Int(setTime)) | \(Int(getRps)) | \(Int(getTime)) |\n"
        }

        cmd("FLUSHDB")
        md += "\n"
        return md
    }

    private func benchXaddThroughput() -> String {
        log("\n--- 3. XADD Throughput ---")
        var md = "## 3. Streams (XADD) Throughput\n\n"

        for count in [1000, 5000, 10000] {
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<count {
                cmd("XADD bench:stream * key val_\(i) ts 1234567890")
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let rps = Double(count) / (elapsed / 1000.0)

            log("\(count) XADD: \(Int(rps)) ops/s (\(Int(elapsed))ms)")
            md += "- \(count) XADD: **\(Int(rps)) ops/sec** (\(Int(elapsed))ms)\n"
        }

        cmd("DEL bench:stream")
        md += "\n"
        return md
    }

    private func benchGeosearch() -> String {
        log("\n--- 4. GEOSEARCH Latency ---")
        var md = "## 4. GEOSEARCH Latency\n\n"

        // Load 1000 geo points
        for i in 0..<1000 {
            let lon = -99.0 + Double.random(in: 0..<2)
            let lat = 19.0 + Double.random(in: 0..<2)
            cmd("GEOADD bench:geo \(lon) \(lat) point:\(i)")
        }
        let count = cmd("ZCARD bench:geo")
        log("Loaded \(count) geo points")

        // Measure GEOSEARCH latency
        let geoResult = measureLatency(iterations: 1000, command: "GEOSEARCH bench:geo FROMLONLAT -99.133 19.432 BYRADIUS 50 km COUNT 100 ASC")
        log("GEOSEARCH 50km: avg=\(f(geoResult.avgMs))ms p50=\(f(geoResult.p50Ms))ms p99=\(f(geoResult.p99Ms))ms")

        let geoWide = measureLatency(iterations: 1000, command: "GEOSEARCH bench:geo FROMLONLAT -99.133 19.432 BYRADIUS 200 km COUNT 1000 ASC")
        log("GEOSEARCH 200km: avg=\(f(geoWide.avgMs))ms p50=\(f(geoWide.p50Ms))ms p99=\(f(geoWide.p99Ms))ms")

        md += "| Query | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |\n"
        md += "|-------|----------|----------|----------|----------|\n"
        md += "| 50km radius, 100 results | \(f(geoResult.avgMs)) | \(f(geoResult.p50Ms)) | \(f(geoResult.p95Ms)) | \(f(geoResult.p99Ms)) |\n"
        md += "| 200km radius, 1000 results | \(f(geoWide.avgMs)) | \(f(geoWide.p50Ms)) | \(f(geoWide.p95Ms)) | \(f(geoWide.p99Ms)) |\n\n"

        cmd("DEL bench:geo")
        return md
    }

    private func benchPersistence() -> String {
        log("\n--- 5. Persistence (AOF) ---")
        var md = "## 5. AOF Persistence\n\n"
        md += "> Note: In-process restart is not possible on iOS (Valkey global state).\n"
        md += "> Verifies all 7 data types write and read correctly,\n"
        md += "> and triggers AOF rewrite to confirm persistence is enabled.\n\n"

        // Write all 7 data types
        cmd("SET persist:string valkey-ios-benchmark")
        cmd("HSET persist:hash name dazzle version 1.0 platform ios")
        cmd("RPUSH persist:list item1 item2 item3")
        cmd("XADD persist:stream * event benchmark ts 1234567890")
        cmd("GEOADD persist:geo -77.0428 -12.0464 Lima")
        cmd("ZADD persist:zset 100 first 200 second 300 third")
        cmd("PFADD persist:hll user1 user2 user3 user4 user5")

        // Trigger AOF rewrite to verify persistence is active
        let aofResult = cmd("BGREWRITEAOF")
        log("BGREWRITEAOF: \(aofResult)")

        // Verify all data types are readable
        md += "| Data Type | Expected | Got | Status |\n"
        md += "|-----------|----------|-----|--------|\n"

        let tests: [(String, String, String)] = [
            ("String", "valkey-ios-benchmark", cmd("GET persist:string")),
            ("Hash (3 fields)", "3", cmd("HLEN persist:hash")),
            ("List (3 items)", "3", cmd("LLEN persist:list")),
            ("Stream (1 entry)", "1", cmd("XLEN persist:stream")),
            ("Geo (1 point)", "1", cmd("ZCARD persist:geo")),
            ("Sorted Set (3)", "3", cmd("ZCARD persist:zset")),
            ("HyperLogLog (5)", "5", cmd("PFCOUNT persist:hll")),
        ]

        for (name, expected, got) in tests {
            let pass = got == expected
            log("\(name): \(pass ? "PASS" : "FAIL") (expected=\(expected), got=\(got))")
            md += "| \(name) | \(expected) | \(got) | \(pass ? "PASS" : "FAIL") |\n"
        }

        cmd("FLUSHDB")
        md += "\n"
        return md
    }

    private func benchMemory(freshMemInfo: String? = nil) -> String {
        log("\n--- 6. Memory Footprint ---")
        var md = "## 6. Memory Footprint\n\n"

        // Use the pre-captured fresh-server snapshot when available (captured before
        // any benchmarks ran, so the hash table is minimal and there's no prior
        // allocator state). Fall back to FLUSHDB measurement for standalone runs.
        cmd("FLUSHDB")
        let memEmpty = freshMemInfo ?? cmd("INFO memory")
        let usedMem = extractInfoField(memEmpty, "used_memory_human")
        let rssMem = extractInfoField(memEmpty, "used_memory_rss_human")
        let peakMem = extractInfoField(memEmpty, "used_memory_peak_human")
        let maxMem = extractInfoField(memEmpty, "maxmemory_human")

        log("Empty: used=\(usedMem), RSS=\(rssMem), peak=\(peakMem), max=\(maxMem)")

        md += "### Empty database\n"
        md += "- used_memory: \(usedMem)\n"
        md += "- used_memory_rss: \(rssMem)\n"
        md += "- used_memory_peak: \(peakMem)\n"
        md += "- maxmemory: \(maxMem)\n\n"

        // After 10K keys
        for i in 0..<10000 {
            cmd("SET memtest:\(i) value_padding_128_bytes_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        }
        let mem10k = cmd("INFO memory")
        let used10k = extractInfoField(mem10k, "used_memory_human")
        let rss10k = extractInfoField(mem10k, "used_memory_rss_human")
        log("10K keys: used=\(used10k), RSS=\(rss10k)")
        md += "### After 10,000 keys (128B values)\n"
        md += "- used_memory: \(used10k)\n"
        md += "- used_memory_rss: \(rss10k)\n\n"

        cmd("FLUSHDB")
        return md
    }

    // MARK: - SQLite Comparison

    private func benchSQLite() -> String {
        log("\n--- 7. SQLite WAL Comparison ---")
        var md = "## 7. SQLite WAL Comparison\n\n"
        md += "> WAL mode + synchronous=NORMAL, same 10K iterations, same value size (112 B).\n"
        md += "> **Architecture note**: SQLite = direct in-process call (no IPC); Valkey = TCP loopback (~0.08 ms overhead per op).\n\n"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbPath = docs.appendingPathComponent("bench_sqlite.db").path
        try? FileManager.default.removeItem(atPath: dbPath)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            log("SQLite ERROR: could not open database")
            md += "ERROR: Could not open SQLite database\n\n"
            return md
        }
        defer {
            sqlite3_close(db)
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        // SQLITE_TRANSIENT: SQLite copies the string before returning (-1 cast)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE bench (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil)

        let iters = 10000
        // Same value length as memtest keys: "value_padding_128_bytes_" (24) + 88 x's = 112 bytes
        let value = "value_padding_128_bytes_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

        // --- 1. INSERT autocommit ---
        log("SQLite INSERT autocommit (\(iters) ops)...")
        var insertLats = [Double]()
        insertLats.reserveCapacity(iters)
        var insertStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO bench VALUES (?,?)", -1, &insertStmt, nil)
        for i in 0..<iters {
            let key = "sqlitetest:\(i)"
            sqlite3_bind_text(insertStmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStmt, 2, value, -1, SQLITE_TRANSIENT)
            let t0 = CFAbsoluteTimeGetCurrent()
            sqlite3_step(insertStmt)
            insertLats.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
            sqlite3_reset(insertStmt)
        }
        sqlite3_finalize(insertStmt)

        insertLats.sort()
        let insAvg = insertLats.reduce(0, +) / Double(iters)
        let insP50 = insertLats[Int(Double(iters) * 0.50)]
        let insP99 = insertLats[Swift.min(Int(Double(iters) * 0.99), iters - 1)]
        let insMax = insertLats.last ?? 0
        log("INSERT autocommit: avg=\(f(insAvg))ms p50=\(f(insP50))ms p99=\(f(insP99))ms max=\(f(insMax))ms")

        // --- 2. SELECT point lookup ---
        log("SQLite SELECT point lookup (\(iters) ops)...")
        var selectLats = [Double]()
        selectLats.reserveCapacity(iters)
        var selectStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT value FROM bench WHERE key=?", -1, &selectStmt, nil)
        for _ in 0..<iters {
            let key = "sqlitetest:\(Int.random(in: 0..<iters))"
            sqlite3_bind_text(selectStmt, 1, key, -1, SQLITE_TRANSIENT)
            let t0 = CFAbsoluteTimeGetCurrent()
            sqlite3_step(selectStmt)
            selectLats.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
            sqlite3_reset(selectStmt)
        }
        sqlite3_finalize(selectStmt)

        selectLats.sort()
        let selAvg = selectLats.reduce(0, +) / Double(iters)
        let selP50 = selectLats[Int(Double(iters) * 0.50)]
        let selP99 = selectLats[Swift.min(Int(Double(iters) * 0.99), iters - 1)]
        let selMax = selectLats.last ?? 0
        log("SELECT: avg=\(f(selAvg))ms p50=\(f(selP50))ms p99=\(f(selP99))ms max=\(f(selMax))ms")

        // --- 3. INSERT in a single transaction ---
        log("SQLite INSERT transaction (\(iters) ops in 1 txn)...")
        sqlite3_exec(db, "DELETE FROM bench", nil, nil, nil)
        var txnStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO bench VALUES (?,?)", -1, &txnStmt, nil)
        let txnStart = CFAbsoluteTimeGetCurrent()
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for i in 0..<iters {
            let key = "sqlitetest:\(i)"
            sqlite3_bind_text(txnStmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(txnStmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(txnStmt)
            sqlite3_reset(txnStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        let txnTotal = (CFAbsoluteTimeGetCurrent() - txnStart) * 1000.0
        sqlite3_finalize(txnStmt)

        let txnPerOp = txnTotal / Double(iters)
        let txnOps = Int(Double(iters) / (txnTotal / 1000.0))
        log("INSERT txn: total=\(f(txnTotal))ms per_op=\(f(txnPerOp))ms ops/s=\(txnOps)")

        // Build markdown
        md += "| Operation | Avg (ms) | p50 (ms) | p99 (ms) | Max (ms) |\n"
        md += "|-----------|----------|----------|----------|----------|\n"
        md += "| INSERT autocommit | \(f(insAvg)) | \(f(insP50)) | \(f(insP99)) | \(f(insMax)) |\n"
        md += "| SELECT point lookup | \(f(selAvg)) | \(f(selP50)) | \(f(selP99)) | \(f(selMax)) |\n"
        md += "| INSERT in transaction (per op) | \(f(txnPerOp)) | — | — | — |\n\n"
        md += "- Transaction throughput: **\(txnOps) ops/sec** (\(iters) ops in \(f(txnTotal)) ms)\n\n"

        return md
    }

    // MARK: - Direct In-Process Benchmark

    private func benchDirect() -> String {
        log("\n--- 8. Direct In-Process vs TCP Latency ---")
        var md = "## 8. Direct In-Process vs TCP Latency\n\n"
        md += "> Direct path: app thread → self-pipe → Valkey event loop (no socket, no TCP stack).\n\n"

        let iters = 10000

        // Warmup direct path
        for i in 0..<100 { _ = server.directCommand("SET warmup:\(i) v") }
        server.command("FLUSHDB")

        // Direct SET
        var dSetLats = [Double](); dSetLats.reserveCapacity(iters)
        for i in 0..<iters {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = server.directCommand("SET bench:d:\(i % 1000) value_data_128bytes_padding_to_simulate_real_world_payload_size_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
            dSetLats.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
        }
        dSetLats.sort()
        let dSetAvg = dSetLats.reduce(0, +) / Double(iters)
        let dSetP50 = dSetLats[Int(Double(iters) * 0.50)]
        let dSetP95 = dSetLats[Int(Double(iters) * 0.95)]
        let dSetP99 = dSetLats[Swift.min(Int(Double(iters) * 0.99), iters - 1)]

        // Direct GET
        var dGetLats = [Double](); dGetLats.reserveCapacity(iters)
        for _ in 0..<iters {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = server.directCommand("GET bench:d:\(Int.random(in: 0..<1000))")
            dGetLats.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
        }
        dGetLats.sort()
        let dGetAvg = dGetLats.reduce(0, +) / Double(iters)
        let dGetP50 = dGetLats[Int(Double(iters) * 0.50)]
        let dGetP95 = dGetLats[Int(Double(iters) * 0.95)]
        let dGetP99 = dGetLats[Swift.min(Int(Double(iters) * 0.99), iters - 1)]

        log("Direct SET: avg=\(f(dSetAvg))ms p50=\(f(dSetP50))ms p95=\(f(dSetP95))ms p99=\(f(dSetP99))ms")
        log("Direct GET: avg=\(f(dGetAvg))ms p50=\(f(dGetP50))ms p95=\(f(dGetP95))ms p99=\(f(dGetP99))ms")

        // TCP SET/GET for comparison
        let tcpSet = measureLatency(iterations: iters, command: "SET bench:t:\(Int.random(in: 0..<1000)) value_data_128bytes_padding_to_simulate_real_world_payload_size_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        let tcpGet = measureLatency(iterations: iters, command: "GET bench:t:\(Int.random(in: 0..<1000))")
        log("TCP    SET: avg=\(f(tcpSet.avgMs))ms p50=\(f(tcpSet.p50Ms))ms p95=\(f(tcpSet.p95Ms))ms p99=\(f(tcpSet.p99Ms))ms")
        log("TCP    GET: avg=\(f(tcpGet.avgMs))ms p50=\(f(tcpGet.p50Ms))ms p95=\(f(tcpGet.p95Ms))ms p99=\(f(tcpGet.p99Ms))ms")

        md += "| Command | Transport | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |\n"
        md += "|---------|-----------|----------|----------|----------|----------|\n"
        md += "| SET | Direct | \(f(dSetAvg)) | \(f(dSetP50)) | \(f(dSetP95)) | \(f(dSetP99)) |\n"
        md += "| SET | TCP    | \(f(tcpSet.avgMs)) | \(f(tcpSet.p50Ms)) | \(f(tcpSet.p95Ms)) | \(f(tcpSet.p99Ms)) |\n"
        md += "| GET | Direct | \(f(dGetAvg)) | \(f(dGetP50)) | \(f(dGetP95)) | \(f(dGetP99)) |\n"
        md += "| GET | TCP    | \(f(tcpGet.avgMs)) | \(f(tcpGet.p50Ms)) | \(f(tcpGet.p95Ms)) | \(f(tcpGet.p99Ms)) |\n\n"

        let setSpeedup = dSetP50 > 0 ? tcpSet.p50Ms / dSetP50 : 0
        let getSpeedup = dGetP50 > 0 ? tcpGet.p50Ms / dGetP50 : 0
        md += "- SET speedup: **\(String(format: "%.1f", setSpeedup))x** (TCP p50 / Direct p50)\n"
        md += "- GET speedup: **\(String(format: "%.1f", getSpeedup))x** (TCP p50 / Direct p50)\n\n"

        cmd("FLUSHDB")
        return md
    }

    // MARK: - Battery / CPU Overhead

    /// Total CPU seconds consumed by this process (user + system, all live threads).
    /// Uses TASK_THREAD_TIMES_INFO so it captures the Valkey event-loop thread.
    private func taskCPUSeconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
        let sys  = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
        return user + sys
    }

    private func benchBattery() -> String {
        log("\n--- 9. CPU / Battery Overhead ---")
        var md = "## 9. CPU / Battery Overhead\n\n"
        md += "> Measures process CPU% at idle, under 100 TCP ops/s, and under 100 Direct ops/s.\n"
        md += "> Battery estimate: iPhone 12 Pro = 10,780 mWh; ~1.5 mW per 1% CPU (A14 efficiency core).\n\n"

        let sampleSecs: Double = 10.0          // seconds per measurement window
        let targetOps  = 100                   // ops/s for load phases
        let intervalMs = 1_000.0 / Double(targetOps)  // ms between ops

        // ── Phase 1: idle ──────────────────────────────────────────────────────
        log("Battery phase 1/3: idle \(Int(sampleSecs))s …")
        let iCPU0 = taskCPUSeconds(); let iW0 = CFAbsoluteTimeGetCurrent()
        Thread.sleep(forTimeInterval: sampleSecs)
        let iCPU1 = taskCPUSeconds(); let iW1 = CFAbsoluteTimeGetCurrent()
        let idlePct = ((iCPU1 - iCPU0) / (iW1 - iW0)) * 100.0
        log(String(format: "Idle: %.2f%% CPU", idlePct))

        // ── Phase 2: TCP ~100 ops/s ────────────────────────────────────────────
        log("Battery phase 2/3: TCP ~\(targetOps) ops/s \(Int(sampleSecs))s …")
        let tCPU0 = taskCPUSeconds(); let tW0 = CFAbsoluteTimeGetCurrent()
        var tcpOps = 0
        while CFAbsoluteTimeGetCurrent() - tW0 < sampleSecs {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = server.command("SET batt:t:\(tcpOps % 100) v")
            tcpOps += 1
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1_000.0
            let sleepMs = intervalMs - elapsedMs
            if sleepMs > 0.1 { Thread.sleep(forTimeInterval: sleepMs / 1_000.0) }
        }
        let tCPU1 = taskCPUSeconds(); let tW1 = CFAbsoluteTimeGetCurrent()
        let tcpPct   = ((tCPU1 - tCPU0) / (tW1 - tW0)) * 100.0
        let tcpActual = Int(Double(tcpOps) / (tW1 - tW0))
        log(String(format: "TCP %d ops/s: %.2f%% CPU", tcpActual, tcpPct))
        cmd("FLUSHDB")

        // ── Phase 3: Direct ~100 ops/s ─────────────────────────────────────────
        log("Battery phase 3/3: Direct ~\(targetOps) ops/s \(Int(sampleSecs))s …")
        let dCPU0 = taskCPUSeconds(); let dW0 = CFAbsoluteTimeGetCurrent()
        var dirOps = 0
        while CFAbsoluteTimeGetCurrent() - dW0 < sampleSecs {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = server.directCommand("SET batt:d:\(dirOps % 100) v")
            dirOps += 1
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1_000.0
            let sleepMs = intervalMs - elapsedMs
            if sleepMs > 0.1 { Thread.sleep(forTimeInterval: sleepMs / 1_000.0) }
        }
        let dCPU1 = taskCPUSeconds(); let dW1 = CFAbsoluteTimeGetCurrent()
        let dirPct    = ((dCPU1 - dCPU0) / (dW1 - dW0)) * 100.0
        let dirActual = Int(Double(dirOps) / (dW1 - dW0))
        log(String(format: "Direct %d ops/s: %.2f%% CPU", dirActual, dirPct))
        cmd("FLUSHDB")

        // ── Battery math ───────────────────────────────────────────────────────
        let battMWh  = 10_780.0   // iPhone 12 Pro rated capacity
        let mwPerPct = 1.5        // ~1.5 mW per 1% CPU on A14 efficiency core

        func drainHours(_ pct: Double) -> String {
            let mw = pct * mwPerPct
            guard mw > 0.01 else { return ">9999 h" }
            return String(format: "%.0f h", battMWh / mw)
        }
        func pctStr(_ v: Double) -> String { String(format: "%.2f%%", v) }
        func mwStr (_ v: Double) -> String { String(format: "%.1f mW", v * mwPerPct) }

        md += "| Phase | CPU% | Extra power | Idle-only battery drain |\n"
        md += "|-------|------|-------------|-------------------------|\n"
        md += "| Idle (no ops) | \(pctStr(idlePct)) | \(mwStr(idlePct)) | \(drainHours(idlePct)) |\n"
        md += "| TCP \(tcpActual) ops/s | \(pctStr(tcpPct)) | \(mwStr(tcpPct)) | \(drainHours(tcpPct)) |\n"
        md += "| Direct \(dirActual) ops/s | \(pctStr(dirPct)) | \(mwStr(dirPct)) | \(drainHours(dirPct)) |\n\n"

        let tcpExtra = max(tcpPct - idlePct, 0.0)
        let dirExtra = max(dirPct - idlePct, 0.0)
        md += String(format: "> Incremental cost above idle — TCP: +%.2f%%  |  Direct: +%.2f%%\n\n", tcpExtra, dirExtra)
        md += "> \"Idle-only drain\" is the hours the *entire* battery would last if Valkey were the only consumer.\n"
        md += "> In practice Valkey's idle share is a small fraction of total device power draw.\n\n"

        return md
    }

    // MARK: - Formatting

    private func f(_ val: Double) -> String {
        String(format: "%.3f", val)
    }

    private func extractInfoField(_ info: String, _ field: String) -> String {
        let prefix = field + ":"
        // Use "\r\n" string split — Valkey INFO uses CRLF endings.
        // Swift treats \r\n as a single grapheme cluster, so split(separator: "\n")
        // would never match; components(separatedBy:) uses raw string matching.
        for line in info.components(separatedBy: "\r\n") {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "N/A"
    }
}
