// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class SortedSetKeyTests: DazzleTestCase {

    func testAddAndScoreMatch() throws {
        let z = dazzle.sortedSet("leaderboard")
        XCTAssertTrue(try z.add(score: 10.0, member: "alice"))
        XCTAssertEqual(try z.score("alice"), 10.0)
        XCTAssertNil(try z.score("missing"))
    }

    func testAddAllReturnsNewMemberCount() throws {
        let z = dazzle.sortedSet("z1")
        XCTAssertEqual(try z.addAll(["a": 1.0, "b": 2.0, "c": 3.0]), 3)
    }

    func testRangeReturnsMembersInScoreOrder() throws {
        let z = dazzle.sortedSet("z2")
        _ = try z.addAll(["b": 20.0, "a": 10.0, "c": 30.0])
        XCTAssertEqual(try z.range(0, -1), ["a", "b", "c"])
    }

    func testRangeByScoreFiltersWindow() throws {
        let z = dazzle.sortedSet("anomalies")
        _ = try z.addAll(["5": 5.0, "15": 15.0, "25": 25.0, "35": 35.0])
        XCTAssertEqual(try z.rangeByScore(min: 10.0, max: 30.0), ["15", "25"])
    }

    func testRankAndRevRankMatchOrder() throws {
        let z = dazzle.sortedSet("z3")
        _ = try z.addAll(["a": 1.0, "b": 2.0, "c": 3.0])
        XCTAssertEqual(try z.rank("a"), 0)
        XCTAssertEqual(try z.rank("c"), 2)
        XCTAssertEqual(try z.revRank("c"), 0)
        XCTAssertEqual(try z.revRank("a"), 2)
    }

    func testIncrByAdjustsExistingScore() throws {
        let z = dazzle.sortedSet("z4")
        _ = try z.add(score: 10.0, member: "x")
        let after = try z.incrBy("x", 2.5)
        XCTAssertEqual(after, 12.5, accuracy: 1e-9)
    }

    func testRemoveDropsSpecificMembers() throws {
        let z = dazzle.sortedSet("z5")
        _ = try z.addAll(["a": 1.0, "b": 2.0, "c": 3.0])
        XCTAssertEqual(try z.remove("a", "missing"), 1)
        XCTAssertEqual(try z.cardinality(), 2)
    }

    func testCountRespectsScoreWindow() throws {
        let z = dazzle.sortedSet("z6")
        _ = try z.addAll(["a": 1.0, "b": 2.0, "c": 3.0, "d": 4.0])
        XCTAssertEqual(try z.count(min: 2.0, max: 3.0), 2)
    }

    func testRangeWithScoresAttachesScore() throws {
        let z = dazzle.sortedSet("z7")
        _ = try z.addAll(["a": 1.0, "b": 2.0])
        let pairs = try z.rangeWithScores(0, -1)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].member, "a")
        XCTAssertEqual(pairs[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(pairs[1].member, "b")
    }
}
