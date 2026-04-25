// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class ContextStoreTests: DazzleTestCase {

    struct ChatMessage: Sendable {
        let role: String
        let text: String
        let timestamp: Int64
    }

    struct SensorReading: Sendable {
        let sensorId: String
        let temp: Double
        let humidity: Double
        let timestamp: Int64
        let anomalous: Bool
    }

    private func makeChatStore() -> DazzleContextStore<ChatMessage> {
        dazzle.contextStore(
            name: "chat:test",
            encode: { m in [
                "role": m.role,
                "text": m.text,
                "timestamp": String(m.timestamp),
            ] },
            decode: { f in
                guard let role = f["role"], let text = f["text"],
                      let ts = f["timestamp"].flatMap(Int64.init) else { return nil }
                return ChatMessage(role: role, text: text, timestamp: ts)
            },
            config: { b in
                b.timeRange { $0.timestamp }
                b.tags { ["role:\($0.role)"] }
            }
        )
    }

    private func makeSensorStore() -> DazzleContextStore<SensorReading> {
        dazzle.contextStore(
            name: "sensors:test",
            encode: { r in [
                "sensor_id": r.sensorId,
                "temp": String(r.temp),
                "humidity": String(r.humidity),
                "timestamp": String(r.timestamp),
                "anomalous": r.anomalous ? "true" : "false",
            ] },
            decode: { f in
                guard let id = f["sensor_id"], let ts = f["timestamp"].flatMap(Int64.init) else { return nil }
                return SensorReading(
                    sensorId: id,
                    temp: f["temp"].flatMap(Double.init) ?? 0,
                    humidity: f["humidity"].flatMap(Double.init) ?? 0,
                    timestamp: ts,
                    anomalous: f["anomalous"] == "true"
                )
            },
            config: { b in
                b.timeRange { $0.timestamp }
                b.tags { r in
                    var t = Set<String>(); t.insert("sensor:\(r.sensorId)")
                    if r.anomalous { t.insert("anomalous") }
                    return t
                }
            }
        )
    }

    func testPutThenGetRoundTrips() throws {
        let chat = makeChatStore()
        defer { try? chat.flush(); chat.close() }
        try chat.flush()
        try chat.put(id: "m:1", value: ChatMessage(role: "user", text: "hola", timestamp: 1000))
        let got = chat.get(id: "m:1")
        XCTAssertNotNil(got)
        XCTAssertEqual(got?.role, "user")
        XCTAssertEqual(got?.text, "hola")
    }

    func testGetOnMissingReturnsNil() {
        let chat = makeChatStore()
        defer { chat.close() }
        XCTAssertNil(chat.get(id: "never"))
    }

    func testDeleteRemovesRecord() throws {
        let chat = makeChatStore()
        defer { try? chat.flush(); chat.close() }
        try chat.flush()
        try chat.put(id: "m:2", value: ChatMessage(role: "assistant", text: "bye", timestamp: 2000))
        XCTAssertTrue(chat.delete(id: "m:2"))
        XCTAssertNil(chat.get(id: "m:2"))
        XCTAssertFalse(chat.delete(id: "m:2"))   // idempotent
    }

    func testByTimeRangeFilters() throws {
        let chat = makeChatStore()
        defer { try? chat.flush(); chat.close() }
        try chat.flush()
        try chat.put(id: "m:1", value: ChatMessage(role: "user", text: "a", timestamp: 100))
        try chat.put(id: "m:2", value: ChatMessage(role: "user", text: "b", timestamp: 200))
        try chat.put(id: "m:3", value: ChatMessage(role: "user", text: "c", timestamp: 300))
        try chat.put(id: "m:4", value: ChatMessage(role: "user", text: "d", timestamp: 400))

        let mid = chat.byTimeRange(start: 150, end: 350).map { $0.0 }
        XCTAssertEqual(Set(mid), Set(["m:2", "m:3"]))
    }

    func testByTagsIntersection() throws {
        let sensors = makeSensorStore()
        defer { try? sensors.flush(); sensors.close() }
        try sensors.flush()
        try sensors.put(id: "r:1", value: SensorReading(sensorId: "alpha", temp: 22, humidity: 48, timestamp: 1000, anomalous: false))
        try sensors.put(id: "r:2", value: SensorReading(sensorId: "alpha", temp: 45, humidity: 40, timestamp: 2000, anomalous: true))
        try sensors.put(id: "r:3", value: SensorReading(sensorId: "beta",  temp: 26, humidity: 55, timestamp: 3000, anomalous: true))

        var hits = Set<String>()
        let iter = sensors.byTags(allOf: ["sensor:alpha", "anomalous"])
        while let (id, _) = iter.next() { hits.insert(id) }
        XCTAssertEqual(hits, ["r:2"])
    }

    func testFlushClearsEverything() throws {
        let chat = makeChatStore()
        defer { chat.close() }
        try chat.put(id: "m:1", value: ChatMessage(role: "user", text: "hello", timestamp: 100))
        try chat.put(id: "m:2", value: ChatMessage(role: "user", text: "world", timestamp: 200))
        try chat.flush()
        XCTAssertEqual(try chat.count(), 0)
        XCTAssertNil(chat.get(id: "m:1"))
        XCTAssertTrue(chat.byTimeRange(start: 0, end: Int64.max).isEmpty)
    }

    func testPutAllAndCountMatch() throws {
        let chat = makeChatStore()
        defer { try? chat.flush(); chat.close() }
        try chat.flush()
        try chat.putAll([
            "m:1": ChatMessage(role: "user",      text: "a", timestamp: 1000),
            "m:2": ChatMessage(role: "assistant", text: "b", timestamp: 2000),
            "m:3": ChatMessage(role: "user",      text: "c", timestamp: 3000),
        ])
        XCTAssertEqual(try chat.count(), 3)
    }

    func testByTagReturnsMembersAcrossRecords() throws {
        let chat = makeChatStore()
        defer { try? chat.flush(); chat.close() }
        try chat.flush()
        try chat.put(id: "m:1", value: ChatMessage(role: "user",      text: "a", timestamp: 100))
        try chat.put(id: "m:2", value: ChatMessage(role: "assistant", text: "b", timestamp: 200))
        try chat.put(id: "m:3", value: ChatMessage(role: "user",      text: "c", timestamp: 300))

        var users = Set<String>()
        let iter = chat.byTag("role:user")
        while let (id, _) = iter.next() { users.insert(id) }
        XCTAssertEqual(users, ["m:1", "m:3"])
    }

    func testIterateYieldsAllStoredRecords() throws {
        let sensors = makeSensorStore()
        defer { try? sensors.flush(); sensors.close() }
        try sensors.flush()
        for i in 0..<5 {
            try sensors.put(
                id: "r:\(i)",
                value: SensorReading(
                    sensorId: "s\(i)", temp: Double(i), humidity: 50,
                    timestamp: Int64(i) * 100, anomalous: false
                )
            )
        }
        var ids = Set<String>()
        let iter = sensors.iterate()
        while let (id, _) = iter.next() { ids.insert(id) }
        XCTAssertEqual(ids, ["r:0", "r:1", "r:2", "r:3", "r:4"])
    }

    func testEncodeReservedFieldIsRejected() {
        let bad = dazzle.contextStore(
            name: "chat:bad",
            encode: { (_: ChatMessage) in ["_embedding": "stolen"] },
            decode: { _ in ChatMessage(role: "user", text: "x", timestamp: 0) }
        )
        defer { bad.close() }
        XCTAssertThrowsError(
            try bad.put(id: "x", value: ChatMessage(role: "user", text: "y", timestamp: 0))
        ) { error in
            guard case DazzleError.transportError(let msg) = error else {
                XCTFail("expected DazzleError.transportError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("_embedding"))
        }
    }
}
