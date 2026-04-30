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

// ─────────────────────────────────────────────────────────────────────────────
// SensorDataset  —  loads the shared dataset_iot_baseline.json used in both platforms
// ─────────────────────────────────────────────────────────────────────────────

/// NAMUR NE43-style sensor status codes. Real industrial sensors ship
/// these alongside the measurement; pre-fault windows often contain
/// NO_DATA flickers or OUT_OF_RANGE spikes before the full fault.
enum SensorStatus: String, Codable {
    case OK
    case NO_DATA
    case OUT_OF_RANGE
    case FAULT
    case CALIB_ERROR

    var isFault: Bool { self != .OK }
}

struct DatasetReading: Codable {
    let minute:    Int
    let timestamp: String
    let temp_c:    Double
    let humidity:  Double
    let anomalous: Bool
    /// Sensor status at this reading. Defaults to OK when absent from JSON
    /// for backward compatibility with legacy datasets.
    let status_code: SensorStatus?

    var tempC: Double { temp_c }
    var statusCode: SensorStatus { status_code ?? .OK }
}

struct DatasetMeta: Codable {
    let seed:          Int
    let num_readings:  Int
    let anomaly_threshold_high: Double
    let anomaly_threshold_low:  Double
    let version:     Int?
    let description: String?
}

struct DatasetStats: Codable {
    let count:          Int
    let avg_temp:       Double
    let min_temp:       Double
    let max_temp:       Double
    let anomaly_count:  Int
    let anomaly_minutes: [Int]
}

struct SensorDataset: Codable {
    let meta:     DatasetMeta
    let stats:    DatasetStats
    let readings: [DatasetReading]

    /// Load from the app bundle. Defaults to dataset_iot_valkey9.json (400 readings
    /// with NAMUR NE43 status codes). Falls back to v2 for builds that
    /// haven't bundled v3 yet.
    static func load(filename: String = "dataset_v3") throws -> SensorDataset {
        let url = Bundle.main.url(forResource: filename, withExtension: "json")
              ?? Bundle.main.url(forResource: "dataset_v2", withExtension: "json")
              ?? Bundle.main.url(forResource: "dataset_iot_baseline", withExtension: "json")
        guard let url = url else {
            throw NSError(domain: "SensorDataset", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(filename).json not found in bundle"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SensorDataset.self, from: data)
    }

    // ── Checkpoint helpers ─────────────────────────────────────────────────

    /// Evenly-spaced checkpoints: every 20 readings up to end of dataset.
    /// v1 (200 readings) → 10 CPs at 19,39,...,199.
    /// v2 (400 readings) → 20 CPs at 19,39,...,399.
    var checkpointIndices: [Int] { stride(from: 19, through: readings.count - 1, by: 20).map { $0 } }

    /// Returns the window of readings for a given checkpoint index.
    /// Window = readings from (previous checkpoint + 1) to current checkpoint.
    func window(forCheckpoint cpIndex: Int) -> [DatasetReading] {
        let endIdx   = checkpointIndices[cpIndex]
        let startIdx = cpIndex == 0 ? 0 : checkpointIndices[cpIndex - 1] + 1
        return Array(readings[startIdx...endIdx])
    }

    /// True if the dataset contains at least one anomalous reading in the window.
    func windowHasAnomaly(cpIndex: Int) -> Bool {
        window(forCheckpoint: cpIndex).contains { $0.anomalous }
    }

    /// Anomalous minutes within the window.
    func anomalyMinutes(inWindow cpIndex: Int) -> [Int] {
        window(forCheckpoint: cpIndex).filter { $0.anomalous }.map { $0.minute }
    }
}
