// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class StreamKeyTests: DazzleTestCase {

    func testAddReturnsIdAndLengthIncrements() throws {
        let s = dazzle.stream("sensor:readings")
        let id1 = try s.add(fields: [("temp", "22.3"), ("humidity", "48")])
        let id2 = try s.add(fields: [("temp", "23.0")])
        XCTAssertNotNil(id1)
        XCTAssertNotNil(id2)
        XCTAssertEqual(try s.length(), 2)
    }

    func testRangeReturnsOldestFirst() throws {
        let s = dazzle.stream("ts")
        _ = try s.add(fields: [("v", "1")])
        _ = try s.add(fields: [("v", "2")])
        _ = try s.add(fields: [("v", "3")])
        let out = try s.range()
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].fields.first?.1, "1")
        XCTAssertEqual(out[2].fields.first?.1, "3")
    }

    func testRevRangeReturnsNewestFirst() throws {
        let s = dazzle.stream("ts2")
        _ = try s.add(fields: [("v", "1")])
        _ = try s.add(fields: [("v", "2")])
        _ = try s.add(fields: [("v", "3")])
        let out = try s.revRange(count: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].fields.first?.1, "3")
        XCTAssertEqual(out[1].fields.first?.1, "2")
    }

    func testMaxLenExactTrimsStrictly() throws {
        let s = dazzle.stream("bounded")
        for i in 1...10 {
            _ = try s.add(
                fields: [("v", String(i))],
                maxLen: 5,
                trimStrategy: .exact
            )
        }
        XCTAssertEqual(try s.length(), 5)
    }

    func testDeleteKeyRemovesStream() throws {
        let s = dazzle.stream("throwaway")
        _ = try s.add(fields: [("v", "1")])
        XCTAssertTrue(try s.exists())
        XCTAssertTrue(try s.deleteKey())
        XCTAssertFalse(try s.exists())
        XCTAssertEqual(try s.length(), 0)
    }

    func testDeleteByIdsRemovesSpecificEntries() throws {
        let s = dazzle.stream("xdel")
        guard let id1 = try s.add(fields: [("v", "1")]),
              let id2 = try s.add(fields: [("v", "2")]),
              let id3 = try s.add(fields: [("v", "3")])
        else {
            XCTFail("add() did not return an id")
            return
        }
        XCTAssertEqual(try s.length(), 3)
        let dropped = try s.delete(ids: id1, id3)
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(try s.length(), 1)
        _ = id2  // silence unused
    }
}
