// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Loads `iot_windows.json` into Dazzle using the **production-grade**
/// storage pattern the paper benchmarks:
///
/// ```
/// ZSet  samples:iot:windows            score=start_minute, member="w-<n>"
/// Hash  samples:iot:win:w-<n>          { start_minute, end_minute, ... }
/// ```
///
/// The ZSet holds short IDs (≤8 bytes) so `rangeByScoreDirect` stays on
/// the snapshot-cache RESP-free path (~2 µs / HIT). Each hydrate is
/// also Direct (`hgetAllDirect`). Zero RESP on the hot path — ~33 µs /
/// query on iPhone 12 Pro.
enum IotCorpus {

    static let sortedSetKey = "samples:iot:windows"
    static let hashPrefix   = "samples:iot:win:"

    @MainActor private static var loaded = false

    static func loadIntoDazzle() async throws {
        if await isLoaded() { return }

        let url = Bundle.main.url(forResource: "iot_windows", withExtension: "json")
        guard let url = url else {
            throw NSError(
                domain: "IotCorpus", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "iot_windows.json not bundled — check the Resources build phase"])
        }
        let data = try Data(contentsOf: url)
        let windows = try JSONDecoder().decode([IoTWindow].self, from: data)

        let client = DazzleServer.shared.client()
        let sset = client.sortedSet(sortedSetKey)

        // Fresh load every time — 30 rows is cheap.
        _ = try? client.delete(sortedSetKey)
        for win in windows {
            let id = windowId(win.startMinute)
            _ = try? client.delete("\(hashPrefix)\(id)")
            _ = try sset.add(score: Double(win.startMinute), member: id)
            let hash = client.hash("\(hashPrefix)\(id)")
            try hash.setAll([
                "start_minute":     String(win.startMinute),
                "end_minute":       String(win.endMinute),
                "avg_temp_c":       String(win.avgTempC),
                "max_temp_c":       String(win.maxTempC),
                "min_temp_c":       String(win.minTempC),
                "avg_humidity":     String(win.avgHumidity),
                "anomaly_detected": String(win.anomalyDetected),
                "anomaly_type":     win.anomalyType,
                "summary":          win.summary,
            ])
        }
        await markLoaded()
    }

    /// Short ID: 4-digit zero-padded minute → "w-0195". ≤8 bytes, well
    /// within the 128-byte snapshot-cache limit so Direct reads stay hot.
    static func windowId(_ startMinute: Int) -> String {
        String(format: "w-%04d", startMinute)
    }

    @MainActor private static func isLoaded() -> Bool { loaded }
    @MainActor private static func markLoaded()       { loaded = true }
}

// MARK: – Model

struct IoTWindow: Codable, Equatable, Hashable {
    let startMinute:      Int
    let endMinute:        Int
    let avgTempC:         Double
    let maxTempC:         Double
    let minTempC:         Double
    let avgHumidity:      Double
    let anomalyDetected:  Bool
    let anomalyType:      String
    let summary:          String

    enum CodingKeys: String, CodingKey {
        case startMinute     = "start_minute"
        case endMinute       = "end_minute"
        case avgTempC        = "avg_temp_c"
        case maxTempC        = "max_temp_c"
        case minTempC        = "min_temp_c"
        case avgHumidity     = "avg_humidity"
        case anomalyDetected = "anomaly_detected"
        case anomalyType     = "anomaly_type"
        case summary         = "summary"
    }
}
