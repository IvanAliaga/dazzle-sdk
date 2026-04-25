// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class StringKeyTests: DazzleTestCase {

    func testSetAndGetRoundTrip() throws {
        let k = dazzle.string("session:token")
        XCTAssertTrue(try k.set("abc123"))
        XCTAssertEqual(try k.get(), "abc123")
    }

    func testGetOnMissingKeyReturnsNil() throws {
        XCTAssertNil(try dazzle.string("nope").get())
    }

    func testNxGuardBlocksOverwrite() throws {
        let k = dazzle.string("once")
        XCTAssertTrue(try k.set("first", options: StringKey.SetOptions(onlyIfAbsent: true)))
        XCTAssertFalse(try k.set("second", options: StringKey.SetOptions(onlyIfAbsent: true)))
        XCTAssertEqual(try k.get(), "first")
    }

    func testXxGuardBlocksCreate() throws {
        let k = dazzle.string("never")
        XCTAssertFalse(try k.set("x", options: StringKey.SetOptions(onlyIfPresent: true)))
        XCTAssertNil(try k.get())
    }

    func testIncrAndIncrByAreAtomicIntegers() throws {
        let k = dazzle.string("counter")
        XCTAssertEqual(try k.incr(), 1)
        XCTAssertEqual(try k.incr(), 2)
        XCTAssertEqual(try k.incrBy(10), 12)
        XCTAssertEqual(try k.decrBy(3), 9)
        XCTAssertEqual(try k.decr(), 8)
    }

    func testIncrByFloatAddsDouble() throws {
        let k = dazzle.string("fcounter")
        _ = try k.set("10")
        let v = try k.incrByFloat(2.5)
        XCTAssertEqual(v, 12.5, accuracy: 1e-9)
    }

    func testAppendAndLength() throws {
        let k = dazzle.string("blob")
        _ = try k.set("hello")
        XCTAssertEqual(try k.append(" world"), 11)
        XCTAssertEqual(try k.length(), 11)
        XCTAssertEqual(try k.get(), "hello world")
    }

    func testDeleteKeyRemovesValue() throws {
        let k = dazzle.string("ephemeral")
        _ = try k.set("gone")
        XCTAssertTrue(try k.exists())
        XCTAssertTrue(try k.deleteKey())
        XCTAssertFalse(try k.exists())
    }

    func testTtlSecondsSetsExpiry() throws {
        let k = dazzle.string("temp")
        XCTAssertTrue(try k.set("v", options: StringKey.SetOptions(ttlSeconds: 60)))
        let ttl = try dazzle.ttl("temp")
        XCTAssertTrue((1...60).contains(ttl), "ttl=\(ttl) should be in 1..60")
    }
}
