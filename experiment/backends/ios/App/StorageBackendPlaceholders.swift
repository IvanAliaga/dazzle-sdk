// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// The iOS `DazzleBackends` target does not currently compile the full
/// storage backend set used by `DazzleStorage` (sqlite-optimized / lmdb /
/// rocksdb). `StorageOnlyTest` references those symbols in its backend
/// factory, so we provide lightweight placeholders here to keep the
/// vector-benchmark app buildable.
///
/// These shims are never used by the vector bench path (`VECTOR_BENCH=true`);
/// they only satisfy linker/type resolution in this target.
final class LmdbContextManager: StorageBackend {
    private let base = InMemoryContextManager()
    var backendName: String { "LMDB (placeholder)" }
    func flush() { base.flush() }
    func ingest(_ reading: SensorReading) { base.ingest(reading) }
    func buildContextBlock(currentMinute: Int, windowMinutes: Int) -> String {
        base.buildContextBlock(currentMinute: currentMinute, windowMinutes: windowMinutes)
    }
    func buildSynthesisContext() -> String { base.buildSynthesisContext() }
    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        base.storeCheckpointDecision(index: index, minute: minute, anomalyDetected: anomalyDetected, severity: severity, trend: trend)
    }
}

final class RocksDbContextManager: StorageBackend {
    private let base = InMemoryContextManager()
    var backendName: String { "RocksDB (placeholder)" }
    func flush() { base.flush() }
    func ingest(_ reading: SensorReading) { base.ingest(reading) }
    func buildContextBlock(currentMinute: Int, windowMinutes: Int) -> String {
        base.buildContextBlock(currentMinute: currentMinute, windowMinutes: windowMinutes)
    }
    func buildSynthesisContext() -> String { base.buildSynthesisContext() }
    func storeCheckpointDecision(index: Int, minute: Int, anomalyDetected: Bool, severity: String, trend: String) {
        base.storeCheckpointDecision(index: index, minute: minute, anomalyDetected: anomalyDetected, severity: severity, trend: trend)
    }
}
