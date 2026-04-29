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
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MultiAgentTest — iOS mirror of the Android MultiAgentTest harness.
//
// Single-client benchmarks (LLM ExperimentPipelineIoT, StorageOnlyTest) cannot
// validate Plan 02's worker-pool dispatch: with one caller there is nothing
// to parallelize. This harness spins up K concurrent Swift Tasks hammering
// the Dazzle backend with an 80/20 read/write mix for T seconds and reports
// aggregate throughput + per-agent p50/p95 latency.
//
// Mode switch: `setenv("DAZZLE_PARALLEL_READS", "1", 1)` BEFORE the server
// starts. iOS has no `nativeSetEnv` JNI bridge — we set it directly via
// POSIX setenv, which the embedded Dazzle C reads with getenv at boot.
//
// Launch example:
//   xcrun devicectl device process launch --device <UDID> \
//     --environment-variables '{"MODE":"parallel","AGENTS":"8","DURATION":"30"}' \
//     io.dazzle.experiment.multiagent
// ─────────────────────────────────────────────────────────────────────────────

enum MAMode: String {
    case mainThread    = "main_thread"
    case parallelReads = "parallel"

    var envFlag: String {
        switch self {
        case .mainThread:    return "0"
        case .parallelReads: return "1"
        }
    }
}

struct MAOptions {
    var mode: MAMode = .mainThread
    var backend: String = "dazzle-precompute"
    var agents: Int = 8
    var durationSec: Int = 30
    var readPct: Int = 80
    var windowMinutes: Int = 20
    var clusterEnabled: Bool = false
}

struct MultiAgentTest {

    /// Progress callback. Called from arbitrary queues — the UI must marshal.
    static func run(options opts: MAOptions, onProgress: @escaping (String) -> Void) async {
        func say(_ s: String) { print("[MultiAgentTest] \(s)"); onProgress(s) }

        say("═══ MultiAgentTest ═══")
        say("mode=\(opts.mode.rawValue) agents=\(opts.agents) dur=\(opts.durationSec)s " +
            "read=\(opts.readPct)% cluster=\(opts.clusterEnabled)")

        // Flip mode BEFORE starting the embedded server. iOS has no JNI bridge —
        // setenv goes straight to the C runtime the Dazzle lib reads at boot.
        setenv("DAZZLE_PARALLEL_READS", opts.mode.envFlag, 1)
        say("DAZZLE_PARALLEL_READS=\(opts.mode.envFlag)")
        if opts.clusterEnabled {
            setenv("DAZZLE_CLUSTER_ENABLED", "1", 1)
            say("DAZZLE_CLUSTER_ENABLED=1")
        }

        // Server may already be running (App init starts it). In that case the
        // env vars above won't take effect for this run — we need to restart.
        // For the first run after process launch the env is correct; for the
        // button-initiated second run the user must force-quit + relaunch.
        if !DazzleServer.shared.isRunning {
            do {
                say("Starting embedded Dazzle server…")
                try DazzleServer.shared.start(config: DazzleConfig(
                    port: 6380, maxMemory: "32mb",
                    persistence: .none, wipeOnStart: [.aof, .rdb]
                ))
                _ = DazzleServer.shared.waitForReady(timeout: 5.0)
                say("Server ready ✓")
            } catch {
                say("ERROR: server failed to start — \(error)")
                return
            }
        } else {
            say("Server already running (reusing)")
        }

        // Pre-populate (same 200-reading shape as LLM/Storage tests).
        // Wires the main Dazzle variants. Non-Dazzle backends (sqlite/lmdb/etc)
        // are out of scope for Plan-02 C-dispatch measurement.
        let backend: StorageBackend = {
            switch opts.backend.lowercased() {
            case "dazzle":            return DazzleContextManager()
            case "dazzle-lua":        return DazzleLuaContextManager()
            case "dazzle-pipeline":   return DazzlePipelineContextManager()
            case "dazzle-hfe":        return DazzleHFEContextManager()
            case "dazzle-hll":        return DazzleHLLContextManager()
            case "dazzle-precompute":   return DazzlePrecomputeIoTManager()
            case "dazzle-incremental": return DazzleIncrementalIoTManager()
            default:
                print("[MultiAgentTest] Unknown backend '\(opts.backend)' — falling back to Dazzle basic")
                return DazzleContextManager()
            }
        }()
        say("backend: \(backend.backendName) (\(opts.backend))")
        backend.flush()
        say("flushed")

        // Snapshot battery BEFORE the concurrent phase — matches Android schema.
        let batteryBefore = SystemSnapshot.batterySnapshot()
        do {
            let dataset = try SensorDataset.load()
            for (i, r) in dataset.readings.enumerated() {
                backend.ingest(SensorReading(
                    minute: r.minute, tempC: r.tempC,
                    humidity: r.humidity, anomalous: r.anomalous
                ))
                if i > 0 && i % 50 == 0 {
                    say("  ingested \(i)/\(dataset.readings.count)…")
                }
            }
            say("ingested \(dataset.readings.count) readings")
        } catch {
            say("ERROR: dataset load failed — \(error)")
            return
        }

        // Warm up
        for _ in 0..<20 { _ = backend.buildContextBlock(currentMinute: 100) }
        say("warm-up ✓ — launching \(opts.agents) agents for \(opts.durationSec)s")

        // ── Fan out K tasks ─────────────────────────────────────────────────
        let totalReads  = Atomic(0)
        let totalWrites = Atomic(0)
        let startNanos  = DispatchTime.now().uptimeNanoseconds
        let endNanos    = startNanos + UInt64(opts.durationSec) * 1_000_000_000

        // Progress ticker
        let tickerTask = Task {
            var lastOps = 0
            while DispatchTime.now().uptimeNanoseconds < endNanos {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let r = totalReads.value
                let w = totalWrites.value
                let cur = r + w
                let inst = cur - lastOps
                lastOps = cur
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1e9
                say("  t=\(String(format: "%.0f", elapsed))s  ops=\(cur)  (+\(inst) ops/s)")
            }
        }

        var perAgentSamples: [[UInt64]] = Array(repeating: [], count: opts.agents)

        await withTaskGroup(of: (Int, [UInt64]).self) { group in
            for agentId in 0..<opts.agents {
                group.addTask(priority: .userInitiated) {
                    var local: [UInt64] = []
                    local.reserveCapacity(opts.durationSec * 500)
                    var rng = SystemRandomNumberGenerator()
                    // Seeding is approximate — Swift has no seedable RNG in stdlib;
                    // divergent behaviour per agent comes from wallclock + priority mix.
                    while DispatchTime.now().uptimeNanoseconds < endNanos {
                        let isRead = Int.random(in: 0..<100, using: &rng) < opts.readPct
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        if isRead {
                            let minute = 20 + Int.random(in: 0..<180, using: &rng)
                            // Dispatch blocking C call off the cooperative pool thread
                            // so K concurrent tasks don't exhaust the executor (Blocker C fix).
                            _ = await blockingOp { backend.buildContextBlock(currentMinute: minute) }
                            totalReads.increment()
                        } else {
                            let minute = 200 + Int.random(in: 0..<100_000, using: &rng)
                            await blockingOp {
                                backend.ingest(SensorReading(
                                    minute: minute,
                                    tempC: 18.0 + Double.random(in: 0..<15, using: &rng),
                                    humidity: 40.0 + Double.random(in: 0..<40, using: &rng),
                                    anomalous: Int.random(in: 0..<100, using: &rng) < 5
                                ))
                            }
                            totalWrites.increment()
                        }
                        local.append(DispatchTime.now().uptimeNanoseconds - t0)
                    }
                    return (agentId, local)
                }
            }
            for await (id, samples) in group {
                perAgentSamples[id] = samples
            }
        }
        tickerTask.cancel()

        // ── Aggregate ───────────────────────────────────────────────────────
        let allSamples = perAgentSamples.flatMap { $0 }.sorted()
        let totalR = totalReads.value
        let totalW = totalWrites.value
        let total = totalR + totalW
        let opsPerSec = Double(total) / Double(opts.durationSec)

        func pctile(_ sorted: [UInt64], _ q: Double) -> UInt64 {
            guard !sorted.isEmpty else { return 0 }
            let idx = min(Int(Double(sorted.count) * q), sorted.count - 1)
            return sorted[idx]
        }
        let p50 = pctile(allSamples, 0.50)
        let p95 = pctile(allSamples, 0.95)
        let p99 = pctile(allSamples, 0.99)
        let avg = allSamples.isEmpty ? 0.0 :
            Double(allSamples.reduce(0, +)) / Double(allSamples.count)

        say("═══ RESULT ═══")
        say("  total=\(total) reads=\(totalR) writes=\(totalW)")
        say("  throughput=\(String(format: "%.1f", opsPerSec)) ops/s aggregate")
        say("  latency: avg=\(String(format: "%.1f", avg / 1000.0)) µs  " +
            "p50=\(String(format: "%.1f", Double(p50) / 1000.0)) µs  " +
            "p95=\(String(format: "%.1f", Double(p95) / 1000.0)) µs  " +
            "p99=\(String(format: "%.1f", Double(p99) / 1000.0)) µs")

        let perAgentStats: [[String: Any]] = perAgentSamples.enumerated().map { (idx, arr) in
            let sorted = arr.sorted()
            let localAvg = sorted.isEmpty ? 0.0 :
                Double(sorted.reduce(0, +)) / Double(sorted.count)
            return [
                "agent":  idx,
                "ops":    arr.count,
                "p50_us": Double(pctile(sorted, 0.50)) / 1000.0,
                "p95_us": Double(pctile(sorted, 0.95)) / 1000.0,
                "p99_us": Double(pctile(sorted, 0.99)) / 1000.0,
                "avg_us": localAvg / 1000.0,
            ]
        }

        let batteryAfter = SystemSnapshot.batterySnapshot()

        let result: [String: Any] = [
            "type":                  "multiagent_bench",
            "plan":                  "plan02",
            "mode":                  opts.mode.rawValue,
            "backend":               opts.backend,
            "backend_key":           opts.backend.lowercased(),
            "cluster_enabled":       opts.clusterEnabled,
            "agents":                opts.agents,
            "duration_sec":          opts.durationSec,
            "read_pct":              opts.readPct,
            "platform":              "iOS",
            "timestamp":             ISO8601DateFormatter().string(from: Date()),
            "device":                UIDevice.current.model + " (" + UIDevice.current.systemVersion + ")",
            "device_info":           SystemSnapshot.deviceInfo(),
            "battery_before":        batteryBefore,
            "battery_after":         batteryAfter,
            "total_ops":             total,
            "reads":                 totalR,
            "writes":                totalW,
            "aggregate_ops_per_sec": opsPerSec,
            "latency_us": [
                "avg": avg / 1000.0,
                "p50": Double(p50) / 1000.0,
                "p95": Double(p95) / 1000.0,
                "p99": Double(p99) / 1000.0,
            ],
            "per_agent":             perAgentStats,
        ]

        saveJson(result: result, opts: opts, say: say)
    }

    private static func saveJson(result: [String: Any], opts: MAOptions, say: (String) -> Void) {
        guard JSONSerialization.isValidJSONObject(result) else {
            say("ERROR: result dict not JSON-serializable")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result,
                                                      options: [.prettyPrinted, .sortedKeys]) else {
            say("ERROR: JSON serialization failed")
            return
        }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = "\(opts.mode.rawValue)" +
            (opts.clusterEnabled ? "_cluster" : "") +
            "_k\(opts.agents)_\(opts.durationSec)s"
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("multiagent_\(suffix)_\(ts).json")
        do {
            try data.write(to: url)
            say("saved: \(url.path)")
        } catch {
            say("ERROR writing JSON: \(error)")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// blockingOp — dispatches a synchronous (blocking) closure onto a global
// background queue and bridges the result back into the Swift concurrency
// world via withCheckedContinuation. Mirrors Kotlin's withContext(Dispatchers.IO):
// each blocking JNI/C call gets its own background thread, so K concurrent
// Tasks on the cooperative pool can all progress without exhausting it.
// ─────────────────────────────────────────────────────────────────────────────

@discardableResult
func blockingOp<T>(_ block: @escaping () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(returning: block())
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal thread-safe counter — NSLock + Int. An actor-based version would
// also work, but calling await from inside a tight inner loop costs ~100ns+
// per call on A14 and pollutes the measurement. Plain lock wins here.
// ─────────────────────────────────────────────────────────────────────────────

final class Atomic {
    private var _value: Int
    private let lock = NSLock()
    init(_ v: Int) { _value = v }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}
