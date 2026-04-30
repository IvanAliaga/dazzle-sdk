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

/// Quick storage-only test that validates a backend WITHOUT Gemma.
/// Runs in ~1 second: ingests 200 readings, builds context blocks,
/// reports retrieval latency and token count. No inference.
///
/// Writes a JSON result file to Documents/ with device metadata,
/// per-checkpoint retrieval latencies, and token counts.
///
/// Wrapped in `extension Paper2` so the enum coexists with the main baseline
/// (storage/ios/StorageOnlyTest.swift) and the Valkey 8 precursor variant.
extension Paper2 {

enum StorageOnlyTest {

    static func run(backendName: String) {
        if backendName.lowercased() == "dazzle-vector" {
            // VectorSearchTest is only available in the backends app target
            print("[StorageTest] dazzle-vector storage test — use DazzleVectorIoTValkey9Paper2Manager via LLM experiment")
            return
        }
        print("[StorageTest] ═══ Storage-only test: \(backendName) ═══")

        let deviceInfo = collectDeviceInfo()

        // Create backend
        let backend = createBackend(name: backendName)
        print("[StorageTest] Backend: \(backend.backendName)")
        backend.flush()

        // Load dataset
        let dataset: SensorDataset
        do {
            dataset = try SensorDataset.load()
        } catch {
            print("[StorageTest] ERROR: failed to load dataset: \(error)")
            return
        }
        print("[StorageTest] Dataset: \(dataset.readings.count) readings, \(dataset.stats.anomaly_count) anomalies")

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
        print("[StorageTest] ═══ DONE ═══")
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
        case "dazzle-vector":     return DazzleVectorIoTValkey9Paper2Manager()
        // Stock Valkey: RESP over TCP loopback to the same embedded server.
        case "valkey":            return ValkeyContextManager()
        case "sqlite":            return SqliteContextManager()
        case "sqlite-optimized":  return SqliteOptimizedContextManager()
        case "sqlite-precompute": return SqlitePrecomputeContextManager()
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

} // extension Paper2
