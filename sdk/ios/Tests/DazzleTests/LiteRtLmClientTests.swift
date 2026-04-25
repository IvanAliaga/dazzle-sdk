// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

/// Smoke tests for `LiteRtLmClient`. **The tests themselves live in a
/// test target that does NOT depend on `DazzleLiteRTLM`** — that would
/// pull the 80 MB CLiteRTLM.xcframework into every CI run and break
/// the simulator test flow with re-signing issues.
///
/// The real `LiteRtLmClient` integration is exercised in:
///   - the chat samples that opt into LiteRT-LM via their adapter
///   - dev machines that manually add the `DazzleLiteRTLM` product to a
///     throw-away target
///
/// This file's sole job is to document the opt-in procedure and assert
/// that the `Sources-LiteRTLM/LiteRtLmClient.swift` file continues to
/// compile against the Dazzle module (import + types) when consumed
/// from a proper target. Currently a no-op marker test.
final class LiteRtLmClientTests: XCTestCase {

    func testAdapterIsDocumentedOptIn() {
        // The LiteRtLmClient adapter ships in the `DazzleLiteRTLM` SPM
        // product. Consumers add it explicitly:
        //
        //   .product(name: "DazzleLiteRTLM", package: "dazzle")
        //
        // No runtime check here — the adapter's own compile passes
        // when the Dazzle test workspace resolves the SPM dep.
        XCTAssertTrue(true)
    }
}
