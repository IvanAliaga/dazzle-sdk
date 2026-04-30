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
import ObjectBox

/// ObjectBox-based StorageBackend for the IoT monitoring agent benchmark.
///
/// Mirrors `experiment/backends/android/objectbox/ObjectBoxContextManager.kt`
/// step-for-step so Android↔iOS comparisons are apples-to-apples on the
/// shared `StorageBackend` protocol surface (ingest → buildContextBlock →
/// buildSynthesisContext → footprint accounting).
///
/// ObjectBox 5.3 ships with HNSW vector search, but we keep the storage-
/// only path here scalar (no vector primitive) because the paper compares
/// vector backends in §5.8 with their own bench. This manager fills the
/// "scalar storage" lane that the Android port already covers, and
/// closes the iPhone gap in Tables 3 and 6 (footprint).
final class ObjectBoxContextManager: StorageBackend {

    let backendName: String = "ObjectBox"

    private let store: Store
    private let dbDir: URL
    private let readingsBox: Box<ReadingEntity>
    private let statsBox: Box<StatsEntity>
    private let anomaliesBox: Box<AnomalyEntity>
    private let decisionsBox: Box<DecisionEntity>
    private let checkpointsBox: Box<CheckpointEntity>

    init() throws {
        // Same wipe-before-open dance as the Kotlin manager so the
        // "before" snapshot starts truly empty and the LMDB-pre-allocated
        // pages don't pin the footprint at a stale high-water mark.
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("objectbox/sensor-experiment-objectbox")
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        self.dbDir = dir

        self.store = try Store(directoryPath: dir.path)
        self.readingsBox    = store.box(for: ReadingEntity.self)
        self.statsBox       = store.box(for: StatsEntity.self)
        self.anomaliesBox   = store.box(for: AnomalyEntity.self)
        self.decisionsBox   = store.box(for: DecisionEntity.self)
        self.checkpointsBox = store.box(for: CheckpointEntity.self)
    }

    deinit {
        // ObjectBox-Swift's `Store` does NOT close on Swift deinit
        // automatically — it only releases the file lock when `.close()`
        // is called explicitly. Without this the next manager instance
        // (e.g. between two test cases on the same simulator path)
        // throws `Cannot open store: another store is still open using
        // the same path`. Validated by the unit test suite.
        store.close()
    }

    // MARK: - Lifecycle

    func flush() {
        // removeAll() releases pages to the freelist but keeps the DB
        // file at its high-water mark; that's the LMDB way under the
        // hood and matches the Android backend behaviour.
        _ = try? readingsBox.removeAll()
        _ = try? statsBox.removeAll()
        _ = try? anomaliesBox.removeAll()
        _ = try? decisionsBox.removeAll()
        _ = try? checkpointsBox.removeAll()
    }

    // MARK: - Ingest

    func ingest(_ reading: SensorReading) {
        // Coalesce every box.put() / .query() / .remove() in a single
        // ingest into ONE write transaction. The Kotlin port relies on
        // ObjectBox-Java's implicit per-put transaction batching to
        // reach ~1.8 ms/r on Moto G35 5G, but ObjectBox-Swift opens a
        // fresh write tx per call (lock + fsync + journal append), and
        // a typical ingest fires ~10 of those (1 put + 1 count, optional
        // query+remove for the trim, 4 upsertStat each doing
        // query+put, 2 min/max checks each doing query+put, optional
        // anomaly query+put + anomaly_count upsert). Without this
        // wrapper the per-reading ingest measured 24 780 µs on iPhone
        // 12 Pro vs 1 839 µs on Moto. Wrapping coalesces the lock
        // overhead and brings the two devices into the same order of
        // magnitude.
        try? store.runInTransaction {
            let entity = ReadingEntity()
            entity.minute    = reading.minute
            entity.temp      = reading.tempC
            entity.humidity  = reading.humidity
            entity.anomalous = reading.anomalous
            _ = try? readingsBox.put(entity)

            // Trim to ~200 entries (rolling window, same as Android). The
            // Kotlin port orders by id; ObjectBox-Swift's `ordered(by:)`
            // requires a value property (third generic = Void), and `id`
            // is a primary-key property (third generic = self), so we
            // order by `minute` instead. The bench dataset has
            // monotonically growing minutes, so this is order-equivalent
            // to ordering by id.
            let count = (try? readingsBox.count()) ?? 0
            if count > 210 {
                if let toRemove = try? readingsBox.query()
                    .ordered(by: ReadingEntity.minute)
                    .build()
                    .find(offset: 0, limit: count - 200) {
                    _ = try? readingsBox.remove(toRemove)
                }
            }

            upsertStat(key: "temp_sum",       value: reading.tempC,            increment: true)
            upsertStat(key: "count",          value: 1.0,                      increment: true)
            upsertStat(key: "latest_temp",    value: reading.tempC,            increment: false)
            upsertStat(key: "latest_minute",  value: Double(reading.minute),   increment: false)

            if let cur = getStat(key: "min_temp") {
                if reading.tempC < cur {
                    upsertStat(key: "min_temp", value: reading.tempC, increment: false)
                }
            } else {
                upsertStat(key: "min_temp", value: reading.tempC, increment: false)
            }
            if let cur = getStat(key: "max_temp") {
                if reading.tempC > cur {
                    upsertStat(key: "max_temp", value: reading.tempC, increment: false)
                }
            } else {
                upsertStat(key: "max_temp", value: reading.tempC, increment: false)
            }

            if reading.anomalous {
                let exists = (try? anomaliesBox.query {
                    AnomalyEntity.minute == reading.minute
                }.build().findFirst()) ?? nil
                if exists == nil {
                    let a = AnomalyEntity()
                    a.minute = reading.minute
                    _ = try? anomaliesBox.put(a)
                }
                upsertStat(key: "anomaly_count", value: 1.0, increment: true)
            }
        }
    }

    // MARK: - Context block

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        var lines: [String] = []

        // Ordered by minute (descending) — same proxy-of-insertion-order
        // pattern as the trim path in `ingest`.
        let recent = (try? readingsBox.query()
            .ordered(by: ReadingEntity.minute, flags: .descending)
            .build()
            .find(offset: 0, limit: 10)) ?? []
        let recentTemps = recent.reversed().map { $0.temp }
        if !recentTemps.isEmpty {
            let formatted = recentTemps.map { String(format: "%.1f", $0) }
                .joined(separator: ", ")
            lines.append("Last \(recentTemps.count) temperatures (oldest\u{2192}newest, \u{00B0}C): \(formatted)")
            lines.append("Recent trend: \(computeTrend(recentTemps))")
        }

        if let s = readStats() {
            lines.append("Aggregate over \(s.count) readings: " +
                "avg=\(String(format: "%.1f", s.avgTemp))\u{00B0}C, " +
                "min=\(String(format: "%.1f", s.minTemp))\u{00B0}C, " +
                "max=\(String(format: "%.1f", s.maxTemp))\u{00B0}C")
            lines.append("Total anomalies detected so far: \(s.anomalyCount)")
        }

        let windowStart = max(0, currentMinute - windowMinutes)
        let windowAnomalies = (try? anomaliesBox.query {
            AnomalyEntity.minute.isBetween(windowStart, and: currentMinute)
        }.ordered(by: AnomalyEntity.minute).build().find()) ?? []
        let mins = windowAnomalies.map { $0.minute }
        if mins.isEmpty {
            lines.append("No anomalies in the last \(windowMinutes) minutes.")
        } else {
            lines.append("Anomalous time indices in the last \(windowMinutes) minutes " +
                "(minute numbers, not temperatures): [\(mins.map(String.init).joined(separator: ", "))]")
        }

        return lines.joined(separator: "\n")
    }

    func buildSynthesisContext() -> String {
        var lines: [String] = []

        if let s = readStats() {
            lines.append("=== Full Session Stats ===")
            lines.append("Total readings: \(s.count)")
            lines.append("Temperature range: \(String(format: "%.1f", s.minTemp))\u{00B0}C to " +
                "\(String(format: "%.1f", s.maxTemp))\u{00B0}C " +
                "(avg \(String(format: "%.1f", s.avgTemp))\u{00B0}C)")
            lines.append("Total anomalies detected: \(s.anomalyCount)")
        }

        let allAnomalies = (try? anomaliesBox.query()
            .ordered(by: AnomalyEntity.minute)
            .build()
            .find()) ?? []
        let allMins = allAnomalies.map { $0.minute }
        if !allMins.isEmpty {
            lines.append("Anomalous time indices (minute numbers, not temperatures): " +
                "[\(allMins.map(String.init).joined(separator: ", "))]")
        }

        let decisions = (try? decisionsBox.query()
            .ordered(by: DecisionEntity.cpIndex)
            .build()
            .find()) ?? []
        if !decisions.isEmpty {
            lines.append("=== Monitoring Agent Decisions ===")
            for d in decisions {
                lines.append("  Checkpoint \(d.cpIndex + 1): \(d.decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Decision storage

    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend)"

        // Same per-call write-tx coalescing as in ingest(): two
        // query+put pairs become one transaction.
        try? store.runInTransaction {
            let existingCp = (try? checkpointsBox.query {
                CheckpointEntity.cpIndex == index
            }.build().findFirst()) ?? nil
            let cp = existingCp ?? CheckpointEntity()
            cp.cpIndex  = index
            cp.minute   = minute
            cp.anomaly  = anomalyDetected
            cp.severity = severity
            cp.trend    = trend
            _ = try? checkpointsBox.put(cp)

            let existingD = (try? decisionsBox.query {
                DecisionEntity.cpIndex == index
            }.build().findFirst()) ?? nil
            let d = existingD ?? DecisionEntity()
            d.cpIndex  = index
            d.decision = decision
            _ = try? decisionsBox.put(d)
        }
    }

    // MARK: - Private helpers

    private struct RunningStats {
        let count: Int
        let avgTemp: Double
        let minTemp: Double
        let maxTemp: Double
        let anomalyCount: Int
    }

    private func readStats() -> RunningStats? {
        guard let count = getStat(key: "count").map({ Int($0) }), count > 0 else {
            return nil
        }
        return RunningStats(
            count: count,
            avgTemp: (getStat(key: "temp_sum") ?? 0.0) / Double(count),
            minTemp: getStat(key: "min_temp") ?? 0.0,
            maxTemp: getStat(key: "max_temp") ?? 0.0,
            anomalyCount: getStat(key: "anomaly_count").map({ Int($0) }) ?? 0
        )
    }

    private func getStat(key: String) -> Double? {
        let row = (try? statsBox.query {
            StatsEntity.key == key
        }.build().findFirst()) ?? nil
        return row?.value
    }

    private func upsertStat(key: String, value: Double, increment: Bool) {
        let existing = (try? statsBox.query {
            StatsEntity.key == key
        }.build().findFirst()) ?? nil
        if let existing = existing {
            existing.value = increment ? existing.value + value : value
            _ = try? statsBox.put(existing)
        } else {
            let s = StatsEntity()
            s.key   = key
            s.value = value
            _ = try? statsBox.put(s)
        }
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
        if slope >  0.15 { return "increasing" }
        if slope < -0.15 { return "decreasing" }
        return "stable"
    }

    // MARK: - Footprint accounting

    var backendSizeMethod: String { "objectbox:dir_st_blocks" }

    /// Sum on-disk usage across the ObjectBox directory using
    /// `st_blocks * 512` (matches `du -k`). Same method as the Android
    /// backend so the iPhone↔Moto numbers in Table 6 are comparable
    /// without further unit gymnastics.
    func backendSizeBytes() -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbDir.path) else { return 0 }
        guard let enumerator = fm.enumerator(at: dbDir,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isFile else { continue }
            // Use `st_blocks * 512` to match `du -k`.
            var st = stat()
            if stat(url.path, &st) == 0 {
                total += Int64(st.st_blocks) * 512
            } else if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
