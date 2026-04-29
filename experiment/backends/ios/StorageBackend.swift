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

/// Pluggable storage backend for the Sequential Monitoring Agent experiment.
///
/// Every implementation stores the same sensor data (200 readings,
/// running aggregates, anomaly indices, agent checkpoint decisions) and
/// builds the same context blocks that get injected into the Gemma prompt.
/// The experiment pipeline accepts a backend name and instantiates the
/// corresponding implementation at run time, so the only variable across
/// runs is the storage engine — model, dataset, and prompt formatting
/// are identical.
protocol StorageBackend {

    /// Human-readable name used in logs and the exported JSON.
    var backendName: String { get }

    /// Delete all stored state (called at the start of each experiment run).
    func flush()

    /// Ingest one sensor reading into the store.
    func ingest(_ reading: SensorReading)

    /// Build a natural-language context block for prompt injection at
    /// a given checkpoint. The exact text must be identical across
    /// backends so the model receives the same prompt.
    func buildContextBlock(currentMinute: Int, windowMinutes: Int) -> String

    /// Full-session context for the CP10 synthesis step.
    func buildSynthesisContext() -> String

    /// Persist the agent's anomaly-detection decision for a checkpoint.
    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String)

    /// Measure round-trip time of `buildContextBlock` in microseconds.
    func measureRetrievalLatency(currentMinute: Int) -> Double

    /// Prediction context for Task 2 — pre-fault signature matching.
    /// Returns an empty string for backends without a precursor index.
    func buildPredictionContext(currentMinute: Int) -> String

    /// Bytes attributable to *this* backend's stored payload, using each
    /// backend's natural primitive (Valkey → `used_memory_dataset`,
    /// SQLite → file size, sparse mapfiles → `st_blocks * 512`, in-memory
    /// → struct estimate). Returns `-1` when the backend cannot answer.
    ///
    /// This is the headline RAM number for §5.2: it is GC- and probe-
    /// noise-free, so it does not get drowned by ART's >10 MB jitter the
    /// way `phys_footprint`/PSS deltas do at small N.
    func backendSizeBytes() -> Int64

    /// Provenance string describing how `backendSizeBytes` was computed.
    /// Examples: "valkey:used_memory_dataset", "sqlite:db_file_size",
    /// "inmemory:struct_estimate".
    var backendSizeMethod: String { get }

    /// Optional fine-grained breakdown for backends whose `backendSizeBytes`
    /// number is one of several published memory stats (e.g. Valkey reports
    /// `used_memory`, `used_memory_dataset`, `used_memory_overhead`,
    /// `used_memory_rss` simultaneously). Returning the full map lets the
    /// JSON consumer choose the right comparison field without re-running.
    /// Returns `nil` for backends with a single number.
    func backendSizeBreakdown() -> [String: Int64]?
}

extension StorageBackend {
    func buildPredictionContext(currentMinute: Int) -> String { "" }

    func buildContextBlock(currentMinute: Int) -> String {
        buildContextBlock(currentMinute: currentMinute, windowMinutes: 20)
    }

    func measureRetrievalLatency(currentMinute: Int) -> Double {
        let start = DispatchTime.now()
        _ = buildContextBlock(currentMinute: currentMinute)
        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000.0  // microseconds
    }

    func backendSizeBytes() -> Int64 { -1 }
    var backendSizeMethod: String { "unknown" }
    func backendSizeBreakdown() -> [String: Int64]? { nil }
}

/// Parse selected numeric fields from a Valkey `INFO memory` bulk-string
/// reply. Returns the keys that were present in the body (any subset of
/// `used_memory`, `used_memory_dataset`, `used_memory_overhead`,
/// `used_memory_rss`, `used_memory_peak`).
///
/// Both iOS and Android run the same Valkey 8 binary, but `used_memory_dataset`
/// is computed only on builds where `used_memory_overhead` is also exported
/// (dataset = used_memory − overhead). Returning the raw dict lets callers
/// log every available field side-by-side instead of silently collapsing to
/// a single number.
func parseValkeyMemoryStats(_ info: String) -> [String: Int64] {
    var out: [String: Int64] = [:]
    let keys: Set<String> = [
        "used_memory",
        "used_memory_dataset",
        "used_memory_overhead",
        "used_memory_rss",
        "used_memory_peak",
    ]
    // CRITICAL: Swift's String.split treats `\r\n` as a single grapheme
    // cluster, so `whereSeparator: { $0 == "\n" || $0 == "\r" }` returns
    // ONE token covering the whole INFO body. We must split on the
    // CharacterSet of newlines instead, which is grapheme-aware.
    for raw in info.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon])
        guard keys.contains(key) else { continue }
        let num = String(line[line.index(after: colon)...])
        if let v = Int64(num) { out[key] = v }
    }
    return out
}

/// Parse the value of `used_memory_dataset` (or fall back to
/// `used_memory`) from a Valkey `INFO memory` bulk-string reply.
///
/// Returns `-1` when the reply does not include either field.
func parseValkeyUsedMemoryDataset(_ info: String) -> Int64 {
    let stats = parseValkeyMemoryStats(info)
    if let v = stats["used_memory_dataset"] { return v }
    if let v = stats["used_memory"]         { return v }
    return -1
}
