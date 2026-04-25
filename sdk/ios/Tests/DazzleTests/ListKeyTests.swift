// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class ListKeyTests: DazzleTestCase {

    func testRpushThenRangeRetainsOrder() throws {
        let l = dazzle.list("queue")
        XCTAssertEqual(try l.rpush("a", "b", "c"), 3)
        XCTAssertEqual(try l.range(0, -1), ["a", "b", "c"])
        XCTAssertEqual(try l.length(), 3)
    }

    func testLpushReversesInsertionOrder() throws {
        let l = dazzle.list("stack")
        _ = try l.lpush("a", "b", "c")
        XCTAssertEqual(try l.range(0, -1), ["c", "b", "a"])
    }

    func testLpopRpopRemoveFromEnds() throws {
        let l = dazzle.list("deque")
        _ = try l.rpush("a", "b", "c", "d")
        XCTAssertEqual(try l.lpop(), "a")
        XCTAssertEqual(try l.rpop(), "d")
        XCTAssertEqual(try l.range(0, -1), ["b", "c"])
    }

    func testPopOnEmptyReturnsNil() throws {
        let l = dazzle.list("empty")
        XCTAssertNil(try l.lpop())
        XCTAssertNil(try l.rpop())
    }

    func testTrimKeepsSubrangeOnly() throws {
        let l = dazzle.list("rolling")
        _ = try l.rpush("1", "2", "3", "4", "5")
        XCTAssertTrue(try l.trim(1, 3))
        XCTAssertEqual(try l.range(0, -1), ["2", "3", "4"])
    }

    func testIndexAndSetMutateByPosition() throws {
        let l = dazzle.list("idx")
        _ = try l.rpush("a", "b", "c")
        XCTAssertEqual(try l.index(1), "b")
        XCTAssertTrue(try l.set(1, "B"))
        XCTAssertEqual(try l.index(1), "B")
    }

    func testRemoveDropsMatchingEntries() throws {
        let l = dazzle.list("dedupe")
        _ = try l.rpush("x", "y", "x", "z", "x")
        let dropped = try l.remove(count: 2, value: "x")
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(try l.range(0, -1), ["y", "z", "x"])
    }

    func testDeleteKeyRemovesList() throws {
        let l = dazzle.list("gone")
        _ = try l.rpush("a")
        XCTAssertTrue(try l.exists())
        XCTAssertTrue(try l.deleteKey())
        XCTAssertFalse(try l.exists())
        XCTAssertEqual(try l.length(), 0)
    }
}
