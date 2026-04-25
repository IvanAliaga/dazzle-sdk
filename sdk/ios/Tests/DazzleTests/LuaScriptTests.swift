// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

final class LuaScriptTests: DazzleTestCase {

    func testEvalReturnsInteger() throws {
        let s = dazzle.script("return 42")
        let r = try s.eval()
        guard case .integer(let v) = r else {
            XCTFail("expected .integer, got \(r)")
            return
        }
        XCTAssertEqual(v, 42)
    }

    func testEvalReadsKeysAndArgs() throws {
        let s = dazzle.script("""
            redis.call('SET', KEYS[1], ARGV[1])
            return redis.call('GET', KEYS[1])
        """)
        let reply = try s.eval(keys: ["k1"], args: ["hello"])
        XCTAssertEqual(reply.asBulkOrNil, "hello")
        XCTAssertEqual(try dazzle.string("k1").get(), "hello")
    }

    func testEvalShaCachesAfterFirstEval() throws {
        let s = dazzle.script("return redis.call('INCR', KEYS[1])")
        let first = try s.eval(keys: ["ctr"])
        let second = try s.evalSha(keys: ["ctr"])
        XCTAssertEqual(first.asInt64OrNil, 1)
        XCTAssertEqual(second.asInt64OrNil, 2)
    }

    func testLoadReturnsSha1() throws {
        let s = dazzle.script("return 'ok'")
        let sha = try s.load()
        XCTAssertEqual(sha.count, 40)
        let reply = try s.evalSha()
        XCTAssertEqual(reply.asBulkOrNil, "ok")
    }

    func testAtomicBoundedIncrementPattern() throws {
        let script = dazzle.script("""
            local cur = redis.call('GET', KEYS[1])
            if cur == false then cur = '0' end
            if tonumber(cur) < tonumber(ARGV[1]) then
                return redis.call('INCR', KEYS[1])
            else
                return -1
            end
        """)
        for _ in 1...5 {
            _ = try script.eval(keys: ["bounded:counter"], args: ["3"])
        }
        XCTAssertEqual(try dazzle.string("bounded:counter").get(), "3")
    }
}
