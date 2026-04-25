// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class HashKeyTests: DazzleTestCase {

    func testSetGetAndSetAllRoundTrip() throws {
        let h = dazzle.hash("sensor:stats")
        XCTAssertTrue(try h.set("count", "0"))
        XCTAssertEqual(try h.get("count"), "0")
        let n = try h.setAll(["temp": "22.3", "humidity": "48"])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try h.get("temp"), "22.3")
    }

    func testGetOnMissingFieldReturnsNil() throws {
        let h = dazzle.hash("h1")
        _ = try h.set("present", "v")
        XCTAssertNil(try h.get("absent"))
    }

    func testMGetAlignsWithInput() throws {
        let h = dazzle.hash("stats")
        _ = try h.setAll(["a": "1", "b": "2"])
        let values = try h.mGet("a", "missing", "b")
        XCTAssertEqual(values, ["1", nil, "2"])
    }

    func testMGetDirectMatchesMGet() throws {
        let h = dazzle.hash("direct")
        _ = try h.setAll(["x": "10", "y": "20"])
        let fromPipe   = try h.mGet("x", "y", "z")
        let fromDirect = try h.mGetDirect("x", "y", "z")
        XCTAssertEqual(fromPipe, fromDirect)
    }

    func testIncrByMutatesAtomically() throws {
        let h = dazzle.hash("counters")
        XCTAssertEqual(try h.incrBy("hits", 1), 1)
        XCTAssertEqual(try h.incrBy("hits", 10), 11)
        let score = try h.incrByFloat("score", 2.5)
        XCTAssertEqual(score, 2.5, accuracy: 1e-9)
    }

    func testGetAllReflectsCurrentState() throws {
        let h = dazzle.hash("h2")
        _ = try h.setAll(["k1": "v1", "k2": "v2"])
        let all = try h.getAll()
        XCTAssertEqual(all, ["k1": "v1", "k2": "v2"])
    }

    func testDeleteFieldsReducesLength() throws {
        let h = dazzle.hash("h3")
        _ = try h.setAll(["a": "1", "b": "2", "c": "3"])
        XCTAssertEqual(try h.delete("a", "b", "missing"), 2)
        XCTAssertEqual(try h.length(), 1)
    }

    func testDeleteKeyRemovesHash() throws {
        let h = dazzle.hash("h4")
        _ = try h.set("k", "v")
        XCTAssertTrue(try h.exists("k"))
        XCTAssertTrue(try h.deleteKey())
        XCTAssertFalse(try h.exists("k"))
    }
}
