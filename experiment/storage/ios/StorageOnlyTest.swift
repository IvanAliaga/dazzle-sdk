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
import UIKit
import Darwin

/// Process-memory probes for the storage bench.
///
/// We prefer `phys_footprint` from `TASK_VM_INFO`: that is the same
/// metric Xcode Instruments and `os_proc_available_memory()` use to
/// account memory against an iOS jetsam budget. It excludes pages
/// shared with the kernel / dyld cache, so the delta between two
/// `phys_footprint` samples tracks new private growth caused by
/// our backend, not the launch overhead of UIKit / dyld.
///
/// We expose `resident_size` (TASK_BASIC_INFO) too as a sanity
/// check — it is what `top` reports and is closer to Linux RSS.
enum MemoryProbeIOS {
    static func physFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kerr != KERN_SUCCESS { return -1 }
        return Int64(info.phys_footprint)
    }

    static func residentSizeBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr != KERN_SUCCESS { return -1 }
        return Int64(info.resident_size)
    }

    /// Best-effort quiesce: drain a couple of autorelease cycles so
    /// the post-ingest reading isn't inflated by transient buffers.
    /// Swift has no `gc()`; this is the closest analogue.
    static func quiesce() {
        for _ in 0..<3 {
            autoreleasepool { }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}

/// Quick storage-only test that validates a backend WITHOUT Gemma.
/// Runs in ~1 second: ingests 200 readings, builds context blocks,
/// reports retrieval latency and token count. No inference.
///
/// Writes a JSON result file to Documents/ with device metadata,
/// per-checkpoint retrieval latencies, and token counts.
enum StorageOnlyTest {

    static func run(backendName: String) {
        print("[StorageTest] ═══ Storage-only test: \(backendName) ═══")

        let deviceInfo = collectDeviceInfo()

        // Create backend
        let backend = createBackend(name: backendName)
        print("[StorageTest] Backend: \(backend.backendName)")
        backend.flush()

        // Pre-ingest memory snapshot. We read both phys_footprint
        // (the Instruments / jetsam metric, our headline number) and
        // resident_size (TASK_BASIC_INFO, RSS-style) after a short
        // quiesce so transient autoreleased buffers from app launch
        // don't inflate the baseline.
        MemoryProbeIOS.quiesce()
        let ramBeforePhysBytes = MemoryProbeIOS.physFootprintBytes()
        let ramBeforeResidentBytes = MemoryProbeIOS.residentSizeBytes()
        let backendSizeBefore = backend.backendSizeBytes()
        let backendBreakdownBefore = backend.backendSizeBreakdown()

        // Load dataset
        let datasetName = ProcessInfo.processInfo.environment["DATASET_NAME"] ?? "dataset_v3"
        let dataset: SensorDataset
        do {
            dataset = try SensorDataset.load(filename: datasetName)
        } catch {
            print("[StorageTest] ERROR: failed to load dataset: \(error)")
            return
        }
        print("[StorageTest] Dataset: \(datasetName) (\(dataset.readings.count) readings, \(dataset.stats.anomaly_count) anomalies)")

        // Ingest all readings (measure throughput)
        let ingestStart = DispatchTime.now()
        for reading in dataset.readings {
            backend.ingest(SensorReading(
                minute:    reading.minute,
                tempC:     reading.tempC,
                humidity:  reading.humidity,
                anomalous: reading.anomalous
            ))
        }
        let ingestNs = DispatchTime.now().uptimeNanoseconds - ingestStart.uptimeNanoseconds
        let ingestMs = Double(ingestNs) / 1_000_000.0
        let perIngestUs = Double(ingestNs) / Double(dataset.readings.count * 1_000)
        print("[StorageTest] Ingest: \(dataset.readings.count) readings in \(String(format: "%.1f", ingestMs)) ms")

        // Post-ingest memory snapshot (same protocol as before).
        MemoryProbeIOS.quiesce()
        let ramAfterPhysBytes = MemoryProbeIOS.physFootprintBytes()
        let ramAfterResidentBytes = MemoryProbeIOS.residentSizeBytes()
        let backendSizeAfter = backend.backendSizeBytes()
        let backendSizeDelta = (backendSizeBefore >= 0 && backendSizeAfter >= 0)
            ? backendSizeAfter - backendSizeBefore : Int64(-1)
        let backendBreakdownAfter = backend.backendSizeBreakdown()

        // Store checkpoint decisions
        for cpIdx in 0..<dataset.checkpointIndices.count {
            let cpReading = dataset.readings[dataset.checkpointIndices[cpIdx]]
            let hasAnomaly = dataset.windowHasAnomaly(cpIndex: cpIdx)
            backend.storeCheckpointDecision(
                index:           cpIdx,
                minute:          cpReading.minute,
                anomalyDetected: hasAnomaly,
                severity:        hasAnomaly ? "high" : "none",
                trend:           "stable"
            )
        }

        // Warm-up: 5 untimed retrievals
        let warmupCp = dataset.readings[dataset.checkpointIndices[4]]
        for _ in 0..<5 { _ = backend.buildContextBlock(currentMinute: warmupCp.minute) }

        // Measure retrieval latency: 10 CPs x 5 iterations = 50 samples
        var latencies: [Double] = []
        for cpIdx in 0..<dataset.checkpointIndices.count {
            let cpReading = dataset.readings[dataset.checkpointIndices[cpIdx]]
            for _ in 0..<5 {
                latencies.append(backend.measureRetrievalLatency(currentMinute: cpReading.minute))
            }
        }
        let sortedLats = latencies.sorted()
        print("[StorageTest] Retrieval: \(String(format: "%.1f", latencies.reduce(0, +) / Double(latencies.count))) µs avg (\(latencies.count) samples)")

        // Build context block for CP5 (token measurement)
        let cp5Reading = dataset.readings[dataset.checkpointIndices[4]]
        let contextBlock = backend.buildContextBlock(currentMinute: cp5Reading.minute)
        let contextTokensEst = contextBlock.count / 4

        // Build synthesis context
        let synthContext = backend.buildSynthesisContext()
        let synthTokensEst = synthContext.count / 4

        // Save JSON result
        let avg = latencies.reduce(0, +) / Double(latencies.count)
        let p50 = sortedLats[sortedLats.count / 2]
        let p95 = sortedLats[min(Int(Double(sortedLats.count) * 0.95), sortedLats.count - 1)]

        // Every numeric value is explicitly bridged via NSNumber so
        // JSONSerialization sees Foundation types end-to-end. Without this
        // the `device` sub-dictionary (UInt64 / Int) triggers
        // "Invalid type in JSON write (__SwiftValue)" on iOS.
        let result: [String: Any] = [
            "type":                   "storage_only",
            "timestamp":              ISO8601DateFormatter().string(from: Date()),
            "device":                 deviceInfo,
            "backend":                backend.backendName,
            "backend_key":            backendName.lowercased(),
            "dataset_name":           datasetName,
            "readings_count":         NSNumber(value: dataset.readings.count),
            "ingest_total_ms":        NSNumber(value: ingestMs),
            "per_ingest_us":          NSNumber(value: perIngestUs),
            "retrieval_samples":      NSNumber(value: latencies.count),
            "retrieval_latencies_us": latencies.map { NSNumber(value: $0) },
            "avg_retrieval_us":       NSNumber(value: avg),
            "median_retrieval_us":    NSNumber(value: p50),
            "min_retrieval_us":       NSNumber(value: sortedLats.first ?? 0),
            "max_retrieval_us":       NSNumber(value: sortedLats.last ?? 0),
            "p50_retrieval_us":       NSNumber(value: p50),
            "p95_retrieval_us":       NSNumber(value: p95),
            "context_chars":          NSNumber(value: contextBlock.count),
            "context_tokens_est":     NSNumber(value: contextTokensEst),
            "synth_chars":            NSNumber(value: synthContext.count),
            "synth_tokens_est":       NSNumber(value: synthTokensEst),
            "ram_before_phys_bytes":  NSNumber(value: ramBeforePhysBytes),
            "ram_after_phys_bytes":   NSNumber(value: ramAfterPhysBytes),
            "ram_delta_phys_bytes":   NSNumber(value: ramAfterPhysBytes - ramBeforePhysBytes),
            "ram_before_phys_kb":     NSNumber(value: ramBeforePhysBytes / 1024),
            "ram_after_phys_kb":      NSNumber(value: ramAfterPhysBytes / 1024),
            "ram_delta_phys_kb":      NSNumber(value: (ramAfterPhysBytes - ramBeforePhysBytes) / 1024),
            "ram_before_resident_bytes": NSNumber(value: ramBeforeResidentBytes),
            "ram_after_resident_bytes":  NSNumber(value: ramAfterResidentBytes),
            "ram_delta_resident_bytes":  NSNumber(value: ramAfterResidentBytes - ramBeforeResidentBytes),
            "ram_before_resident_kb":    NSNumber(value: ramBeforeResidentBytes / 1024),
            "ram_after_resident_kb":     NSNumber(value: ramAfterResidentBytes / 1024),
            "ram_delta_resident_kb":     NSNumber(value: (ramAfterResidentBytes - ramBeforeResidentBytes) / 1024),
            "ram_metric":             "phys_footprint",
            "backend_size_method":       backend.backendSizeMethod,
            "backend_size_before_bytes": NSNumber(value: backendSizeBefore),
            "backend_size_after_bytes":  NSNumber(value: backendSizeAfter),
            "backend_size_delta_bytes":  NSNumber(value: backendSizeDelta),
            "backend_size_breakdown_before_bytes":
                breakdownAsNSNumberDict(backendBreakdownBefore),
            "backend_size_breakdown_after_bytes":
                breakdownAsNSNumberDict(backendBreakdownAfter),
            "backend_size_breakdown_delta_bytes":
                breakdownDeltaAsNSNumberDict(before: backendBreakdownBefore,
                                             after:  backendBreakdownAfter),
        ]

        let safeBackend = backendName.replacingOccurrences(of: "[^a-zA-Z0-9_-]",
            with: "_", options: .regularExpression)
        // Timestamp-suffixed filename so N back-to-back runs produce N
        // distinct JSONs on device and the pull script can scoop every one
        // (mirrors the Android exporter naming scheme).
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let fileName = "storageonly_\(safeBackend)_\(ts).json"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent(fileName)

        guard JSONSerialization.isValidJSONObject(result) else {
            print("[StorageTest] ERROR: result dict not JSON-serializable; skipping write")
            return
        }
        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: fileURL)
            print("[StorageTest] JSON saved: \(fileURL.path)")
        } catch {
            print("[StorageTest] ERROR writing JSON: \(error)")
        }

        print("[StorageTest] ═══ RESULT: \(backend.backendName) ═══")
        print("[StorageTest]   Ingest:      \(String(format: "%.1f", ingestMs)) ms (\(dataset.readings.count) readings)")
        print("[StorageTest]   Per-ingest:  \(String(format: "%.1f", perIngestUs)) µs/reading")
        print("[StorageTest]   Retrieval:   \(String(format: "%.1f", avg)) µs avg")
        print("[StorageTest]   P50/P95:     \(String(format: "%.1f", p50)) / \(String(format: "%.1f", p95)) µs")
        print("[StorageTest]   CP5 tokens:  ~\(contextTokensEst)")
        print("[StorageTest]   Synth tokens: ~\(synthTokensEst)")
        let ramDeltaKb = (ramAfterPhysBytes - ramBeforePhysBytes) / 1024
        print("[StorageTest]   RAM delta:   \(ramDeltaKb) KB (phys_footprint)")
        print("[StorageTest]   Backend size delta: \(backendSizeDelta) bytes (\(backend.backendSizeMethod))")
        print("[StorageTest] ═══ DONE ═══")
    }

    /// iOS equivalent of Android `scale_benchmark` runs:
    /// retrieval/ingest/footprint sweep across N on one backend.
    static func runScale(backendName: String, readingCounts: [Int]) {
        print("[StorageScale] ═══ Scale benchmark: \(backendName) ═══")
        print("[StorageScale] Counts: \(readingCounts)")

        let datasetName = ProcessInfo.processInfo.environment["DATASET_NAME"] ?? "dataset_iot_baseline"
        let dataset: SensorDataset
        do {
            dataset = try SensorDataset.load(filename: datasetName)
        } catch {
            print("[StorageScale] ERROR: failed to load dataset: \(error)")
            return
        }

        let baseReadings: [SensorReading] = dataset.readings.map {
            SensorReading(
                minute: $0.minute,
                tempC: $0.tempC,
                humidity: $0.humidity,
                anomalous: $0.anomalous
            )
        }
        if baseReadings.isEmpty {
            print("[StorageScale] ERROR: empty base dataset")
            return
        }

        var scalePoints: [[String: Any]] = []
        var backendLabelForJson = backendName
        for n in readingCounts where n > 0 {
            let backend = createBackend(name: backendName)
            backendLabelForJson = backend.backendName
            backend.flush()
            let readings = generateReadings(base: baseReadings, n: n)

            MemoryProbeIOS.quiesce()
            let ramBeforePhysBytes = MemoryProbeIOS.physFootprintBytes()
            let ramBeforeResidentBytes = MemoryProbeIOS.residentSizeBytes()
            let backendSizeBefore = backend.backendSizeBytes()
            let backendBreakdownBefore = backend.backendSizeBreakdown()

            let ingestStart = DispatchTime.now()
            for reading in readings {
                backend.ingest(reading)
            }
            let ingestNs = DispatchTime.now().uptimeNanoseconds - ingestStart.uptimeNanoseconds
            let ingestMs = Double(ingestNs) / 1_000_000.0
            let perIngestUs = Double(ingestNs) / Double(readings.count * 1_000)

            let cpIndices = checkpointIndices(for: readings.count)
            var winStart = 0
            for (cpIdx, cpEnd) in cpIndices.enumerated() {
                let cpReading = readings[cpEnd]
                let hasAnomaly = windowHasAnomaly(readings: readings, start: winStart, end: cpEnd)
                backend.storeCheckpointDecision(
                    index: cpIdx,
                    minute: cpReading.minute,
                    anomalyDetected: hasAnomaly,
                    severity: hasAnomaly ? "high" : "none",
                    trend: "stable"
                )
                winStart = cpEnd + 1
            }

            let currentMinute = readings.last?.minute ?? 0
            for _ in 0..<5 { _ = backend.buildContextBlock(currentMinute: currentMinute) }

            var latencies: [Double] = []
            latencies.reserveCapacity(20)
            for _ in 0..<20 {
                latencies.append(backend.measureRetrievalLatency(currentMinute: currentMinute))
            }
            let sorted = latencies.sorted()
            let avgRetrieval = latencies.isEmpty ? 0.0 : latencies.reduce(0, +) / Double(latencies.count)
            let p50 = sorted.isEmpty ? 0.0 : sorted[sorted.count / 2]
            let p95 = sorted.isEmpty ? 0.0 : sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]

            let contextBlock = backend.buildContextBlock(currentMinute: currentMinute)
            let synthContext = backend.buildSynthesisContext()

            MemoryProbeIOS.quiesce()
            let ramAfterPhysBytes = MemoryProbeIOS.physFootprintBytes()
            let ramAfterResidentBytes = MemoryProbeIOS.residentSizeBytes()
            let backendSizeAfter = backend.backendSizeBytes()
            let backendSizeDelta = (backendSizeBefore >= 0 && backendSizeAfter >= 0)
                ? backendSizeAfter - backendSizeBefore : Int64(-1)
            let backendBreakdownAfter = backend.backendSizeBreakdown()

            let point: [String: Any] = [
                "n": NSNumber(value: n),
                "retrieval_avg_us": NSNumber(value: avgRetrieval),
                "retrieval_p50_us": NSNumber(value: p50),
                "retrieval_p95_us": NSNumber(value: p95),
                "ingest_total_ms": NSNumber(value: ingestMs),
                "per_ingest_us": NSNumber(value: perIngestUs),
                "ram_before_kb": NSNumber(value: ramBeforePhysBytes / 1024),
                "ram_after_kb": NSNumber(value: ramAfterPhysBytes / 1024),
                "ram_delta_kb": NSNumber(value: (ramAfterPhysBytes - ramBeforePhysBytes) / 1024),
                "ram_before_pss_kb": NSNumber(value: -1),
                "ram_after_pss_kb": NSNumber(value: -1),
                "ram_delta_pss_kb": NSNumber(value: -1),
                "ram_before_rss_kb": NSNumber(value: ramBeforeResidentBytes / 1024),
                "ram_after_rss_kb": NSNumber(value: ramAfterResidentBytes / 1024),
                "ram_delta_rss_kb": NSNumber(value: (ramAfterResidentBytes - ramBeforeResidentBytes) / 1024),
                "ram_metric": "phys_footprint",
                "backend_size_method": backend.backendSizeMethod,
                "backend_size_before_bytes": NSNumber(value: backendSizeBefore),
                "backend_size_after_bytes": NSNumber(value: backendSizeAfter),
                "backend_size_delta_bytes": NSNumber(value: backendSizeDelta),
                "backend_size_breakdown_before_bytes": breakdownAsNSNumberDict(backendBreakdownBefore),
                "backend_size_breakdown_after_bytes": breakdownAsNSNumberDict(backendBreakdownAfter),
                "backend_size_breakdown_delta_bytes": breakdownDeltaAsNSNumberDict(before: backendBreakdownBefore,
                                                                                   after: backendBreakdownAfter),
                "context_chars": NSNumber(value: contextBlock.count),
                "context_tokens_est": NSNumber(value: contextBlock.count / 4),
                "synth_chars": NSNumber(value: synthContext.count),
                "synth_tokens_est": NSNumber(value: synthContext.count / 4),
                "io_write_bytes_delta": NSNumber(value: -1),
                "concurrent_retrieval_avg_us": NSNumber(value: avgRetrieval),
                "concurrent_retrieval_p95_us": NSNumber(value: p95),
            ]
            scalePoints.append(point)

            print("[StorageScale] N=\(n): retrieval \(String(format: "%.1f", avgRetrieval)) µs, ingest \(String(format: "%.1f", perIngestUs)) µs/reading")
        }

        let safeBackend = backendName.replacingOccurrences(of: "[^a-zA-Z0-9_-]",
                                                           with: "_",
                                                           options: .regularExpression)
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let fileName = "scale_\(safeBackend)_\(ts).json"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent(fileName)

        let result: [String: Any] = [
            "type": "scale_benchmark",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "backend": backendLabelForJson,
            "backend_key": backendName.lowercased(),
            "dataset_name": datasetName,
            "device": collectDeviceInfo(),
            "scale_points": scalePoints,
        ]

        guard JSONSerialization.isValidJSONObject(result) else {
            print("[StorageScale] ERROR: result dict not JSON-serializable; skipping write")
            return
        }
        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: fileURL)
            print("[StorageScale] JSON saved: \(fileURL.path)")
        } catch {
            print("[StorageScale] ERROR writing JSON: \(error)")
        }
    }

    // MARK: - JSON helpers

    private static func breakdownAsNSNumberDict(_ b: [String: Int64]?) -> [String: NSNumber] {
        guard let b else { return [:] }
        var out: [String: NSNumber] = [:]
        for (k, v) in b { out[k] = NSNumber(value: v) }
        return out
    }

    private static func breakdownDeltaAsNSNumberDict(before: [String: Int64]?,
                                                     after:  [String: Int64]?) -> [String: NSNumber] {
        guard let before, let after else { return [:] }
        var out: [String: NSNumber] = [:]
        for (k, vAfter) in after {
            if let vBefore = before[k] { out[k] = NSNumber(value: vAfter - vBefore) }
        }
        return out
    }

    private static func checkpointIndices(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count < 20 { return [count - 1] }
        return stride(from: 19, through: count - 1, by: 20).map { $0 }
    }

    private static func windowHasAnomaly(readings: [SensorReading], start: Int, end: Int) -> Bool {
        guard !readings.isEmpty else { return false }
        let s = max(0, start)
        let e = min(end, readings.count - 1)
        guard s <= e else { return false }
        for i in s...e where readings[i].anomalous { return true }
        return false
    }

    private static func generateReadings(base: [SensorReading], n: Int) -> [SensorReading] {
        guard !base.isEmpty else { return [] }
        if n <= base.count { return Array(base.prefix(n)) }

        var out: [SensorReading] = []
        out.reserveCapacity(n)
        var cycle = 0
        while out.count < n {
            let minuteOffset = cycle * base.count
            for r in base {
                if out.count >= n { break }
                out.append(SensorReading(
                    minute: r.minute + minuteOffset,
                    tempC: r.tempC,
                    humidity: r.humidity,
                    anomalous: r.anomalous
                ))
            }
            cycle += 1
        }
        return out
    }

    // MARK: - Backend factory

    static func createBackend(name: String) -> StorageBackend {
        switch name.lowercased() {
        // Dazzle family: in-process directCommand path.
        case "dazzle":            return DazzleContextManager()
        case "dazzle-lua":        return DazzleLuaContextManager()
        case "dazzle-pipeline":   return DazzlePipelineContextManager()
        case "dazzle-hfe":        return DazzleHFEContextManager()
        case "dazzle-hll":        return DazzleHLLContextManager()
        case "dazzle-precompute": return DazzlePrecomputeIoTManager()
        case "dazzle-vector":     return DazzleVectorIoTValkey9Manager()
        // Stock Valkey: RESP over TCP loopback to the same embedded server.
        case "valkey":            return ValkeyContextManager()
        case "sqlite":            return SqliteContextManager()
        case "sqlite-optimized":  return SqliteOptimizedContextManager()
        case "sqlite-precompute": return SqlitePrecomputeContextManager()
        case "lmdb":              return LmdbContextManager()
        case "rocksdb":           return RocksDbContextManager()
        case "objectbox":
            do { return try ObjectBoxContextManager() }
            catch {
                print("[StorageTest] ObjectBox init failed: \(error) — falling back to InMemory")
                return InMemoryContextManager()
            }
        case "inmemory":          return InMemoryContextManager()
        default:
            print("[StorageTest] Unknown backend '\(name)', falling back to Dazzle")
            return DazzleContextManager()
        }
    }

    // MARK: - Device metadata

    private static func collectDeviceInfo() -> [String: Any] {
        let device = UIDevice.current
        let processInfo = ProcessInfo.processInfo
        // Every numeric value is wrapped in NSNumber explicitly — raw Swift
        // ints/UInts show up as __SwiftValue once this dict is embedded inside
        // another [String: Any] and JSONSerialization bails on them.
        return [
            "model":            device.model,
            "name":             device.name,
            "systemName":       device.systemName,
            "systemVersion":    device.systemVersion,
            "ram_total_bytes":  NSNumber(value: processInfo.physicalMemory),
            "cpu_cores":        NSNumber(value: processInfo.processorCount),
            "active_cpu_cores": NSNumber(value: processInfo.activeProcessorCount),
            "platform":         "iOS",
        ]
    }
}
