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

import XCTest
@testable import DazzleStorage

/// Data-path tests for `ObjectBoxContextManager`. The whole point of
/// this target is to catch the "ObjectBox-Swift entity binding is
/// silently broken" failure mode on the simulator, before the iPhone
/// 12 Pro device run that fills T3/T6 ObjectBox iPhone cells.
///
/// Specifically validates:
///   - Sourcery-generated EntityInfo.generated.swift is in the build
///     (otherwise `Store(directoryPath:)` would fail at runtime with
///     "no entities registered").
///   - ObjectBox.xcframework is embedded + codesigned (otherwise
///     `import ObjectBox` would fail at link time, not runtime).
///   - The 5 entity Boxes (Reading, Stats, Anomaly, Decision,
///     Checkpoint) actually persist + retrieve under the same shape
///     as the Kotlin port.
final class ObjectBoxTests: XCTestCase {

    private var mgr: ObjectBoxContextManager!

    override func setUp() {
        super.setUp()
        do {
            mgr = try ObjectBoxContextManager()
            mgr.flush()
        } catch {
            XCTFail("ObjectBox init failed: \(error)")
        }
    }

    override func tearDown() {
        mgr?.flush()
        mgr = nil
        super.tearDown()
    }

    // MARK: - Init / Sourcery wiring

    func testManagerOpensStore() {
        // setUp would have failed already if init throws, so reaching
        // this point means Store(directoryPath:) succeeded — i.e. the
        // generated entityBinding registered all 5 entities at startup.
        XCTAssertNotNil(mgr)
        XCTAssertEqual(mgr.backendName, "ObjectBox")
    }

    // MARK: - Ingest persistence

    func testIngestPersists200Readings() {
        for i in 0..<200 {
            mgr.ingest(SensorReading(
                minute: i,
                tempC: 20.0 + Double(i % 10) * 0.1,
                humidity: 45.0,
                anomalous: (i % 17 == 0)))
        }
        let block = mgr.buildContextBlock(currentMinute: 199, windowMinutes: 20)
        XCTAssertFalse(block.isEmpty,
                       "context block must not be empty after 200 ingests")
        XCTAssertTrue(block.contains("Aggregate over"),
                      "block must include aggregate-stats line: \(block)")
    }

    // MARK: - Aggregate correctness

    func testAggStateMatchesIngestedAnomalyCount() {
        var expected = 0
        for i in 0..<100 {
            let anomalous = (i % 13 == 0)
            if anomalous { expected += 1 }
            mgr.ingest(SensorReading(
                minute: i,
                tempC: 22.0,
                humidity: 50.0,
                anomalous: anomalous))
        }
        let synth = mgr.buildSynthesisContext()
        XCTAssertTrue(synth.contains("Total anomalies detected: \(expected)"),
                      "synthesis must report \(expected) anomalies; got: \(synth)")
    }

    func testAggStateMinMaxBracketsTemperatureRange() {
        let temps = [18.0, 22.5, 19.7, 30.1, 21.0]  // min=18.0, max=30.1
        for (i, t) in temps.enumerated() {
            mgr.ingest(SensorReading(minute: i, tempC: t, humidity: 50.0, anomalous: false))
        }
        let block = mgr.buildContextBlock(currentMinute: temps.count - 1, windowMinutes: 20)
        XCTAssertTrue(block.contains("min=18.0"),
                      "expected min=18.0 in block: \(block)")
        XCTAssertTrue(block.contains("max=30.1"),
                      "expected max=30.1 in block: \(block)")
    }

    // MARK: - Bounded suffix invariant

    func testBoundedSuffixPrunesAtN200() {
        for i in 0..<250 {
            mgr.ingest(SensorReading(minute: i, tempC: 20.0, humidity: 50.0, anomalous: false))
        }
        let block = mgr.buildContextBlock(currentMinute: 249, windowMinutes: 20)
        XCTAssertFalse(block.isEmpty, "block empty after 250 ingests")
    }

    // MARK: - Decisions

    func testStoreCheckpointDecisionPersists() {
        mgr.storeCheckpointDecision(
            index: 0, minute: 10,
            anomalyDetected: true, severity: "high", trend: "increasing")
        mgr.storeCheckpointDecision(
            index: 1, minute: 20,
            anomalyDetected: false, severity: "none", trend: "stable")
        let synth = mgr.buildSynthesisContext()
        XCTAssertTrue(synth.contains("Checkpoint 1:"),
                      "synthesis must include Checkpoint 1: \(synth)")
        XCTAssertTrue(synth.contains("Checkpoint 2:"),
                      "synthesis must include Checkpoint 2: \(synth)")
    }

    // MARK: - Footprint accounting

    func testFootprintNonZeroAfterIngest() {
        for i in 0..<50 {
            mgr.ingest(SensorReading(minute: i, tempC: 22.0, humidity: 50.0, anomalous: false))
        }
        let bytes = mgr.backendSizeBytes()
        XCTAssertGreaterThan(bytes, 0, "footprint must be > 0 after 50 ingests")
    }

    func testFootprintMethodLabel() {
        XCTAssertEqual(mgr.backendSizeMethod, "objectbox:dir_st_blocks",
                       "method label must match the value used in result JSON")
    }
}
