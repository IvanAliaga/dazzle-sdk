// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Tool the LLM calls when the user asks about sensor data.
///
/// Signature exposed to the model (OpenAI-compatible):
/// ```
/// retrieve_anomalies(min_from: integer, min_to: integer)
///   → [{start_minute, end_minute, avg_temp_c, max_temp_c, avg_humidity,
///       anomaly_detected, anomaly_type, summary}]
/// ```
///
/// Stays entirely on the Direct (snapshot-cache, RESP-free) path:
///   1. `sset.rangeByScoreDirect` → short IDs (snapshot HIT).
///   2. per-ID `hash.getAllDirect` → payload fields (snapshot HIT).
///
/// Benched at ~33 µs / query on iPhone 12 Pro for the full loop.
struct RetrieveAnomaliesTool: Tool {
    typealias Args = TimeRange
    typealias Ret  = [IoTWindow]

    let name        = "retrieve_anomalies"
    let description = """
        Return the sensor windows overlapping [min_from..min_to] from
        the on-device Dazzle store. Each row includes averages, anomaly
        flag, and a one-line summary. Minutes are 0..2399.
        """

    let argsSchema: JsonSchema = jsonSchemaObject(
        description: "Time range (in minutes) to inspect."
    ) {
        $0.property("min_from", type: "integer",
                    description: "Lower-bound minute, inclusive (0..2399).",
                    required: true,
                    minimum: 0, maximum: 2399)
        $0.property("min_to", type: "integer",
                    description: "Upper-bound minute, inclusive (0..2399).",
                    required: true,
                    minimum: 0, maximum: 2399)
    }

    func argsFromJson(_ raw: String) throws -> TimeRange {
        let data = Data(raw.utf8)
        return try JSONDecoder().decode(TimeRange.self, from: data)
    }

    func invoke(args: TimeRange, ctx: ToolContext) async throws -> [IoTWindow] {
        let client = DazzleServer.shared.client()
        let sset   = client.sortedSet(IotCorpus.sortedSetKey)

        // 1) Fast-path range read → short IDs, snapshot-cache HIT.
        let ids = try sset.rangeByScoreDirect(
            min: Double(args.minFrom),
            max: Double(args.minTo))

        // 2) Hydrate each ID via `hgetAllDirect` — also snapshot HIT.
        //    Zero RESP round-trips on either read.
        return ids.compactMap { id in
            guard let fields = try? client.hash("\(IotCorpus.hashPrefix)\(id)").getAllDirect(),
                  !fields.isEmpty else { return nil }
            return hydrate(fields)
        }
    }

    private func hydrate(_ f: [String: String]) -> IoTWindow? {
        guard let sm = f["start_minute"].flatMap(Int.init),
              let em = f["end_minute"].flatMap(Int.init),
              let avgT = f["avg_temp_c"].flatMap(Double.init),
              let maxT = f["max_temp_c"].flatMap(Double.init),
              let minT = f["min_temp_c"].flatMap(Double.init),
              let avgH = f["avg_humidity"].flatMap(Double.init),
              let anom = f["anomaly_detected"].flatMap({ Bool($0) })
        else { return nil }
        return IoTWindow(
            startMinute:     sm,
            endMinute:       em,
            avgTempC:        avgT,
            maxTempC:        maxT,
            minTempC:        minT,
            avgHumidity:     avgH,
            anomalyDetected: anom,
            anomalyType:     f["anomaly_type"] ?? "none",
            summary:         f["summary"] ?? ""
        )
    }

    func returnToJson(_ value: [IoTWindow]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }
}

struct TimeRange: Codable, Sendable {
    let minFrom: Int
    let minTo:   Int

    enum CodingKeys: String, CodingKey {
        case minFrom = "min_from"
        case minTo   = "min_to"
    }
}
