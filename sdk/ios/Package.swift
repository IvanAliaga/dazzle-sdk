// swift-tools-version:5.9
// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// This Swift Package exists so `swift test` can run the XCTest suite against
// the Dazzle SDK primitives. The canonical iOS build path is still the
// experiment apps (which include Sources/*.swift + core/platform/dazzle_ios.c
// directly via xcodegen) — this manifest does not replace that.
//
// Structure:
//   - `DazzleC` module comes from the xcframework's modulemap (binary target)
//     and supplies the function declarations + libvalkey-server.a.
//   - `DazzleSupport` is a source C target that compiles dazzle_ios.c so the
//     wrapper `dazzle_ios_*` symbols resolve at link time. Its generated
//     module is never imported — it's a link-only supplier.
//   - `Dazzle` is the Swift module users of the package import.

import PackageDescription

let package = Package(
    name: "Dazzle",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // Core — everything except the LiteRT-LM runtime. Primitives,
        // ContextStore, Agent, ChatAgent, DazzleEdge factory (sans LLM
        // adapter), ModelDownloader. Adds zero network / ML dependencies.
        .library(name: "Dazzle", targets: ["Dazzle"]),

        // Opt-in: pulls LiteRTLM-Swift (~80 MB CLiteRTLM.xcframework).
        // Consumers that bring their own LLMClient (cloud API, Foundation
        // Models, custom adapter) skip this product and pay nothing.
        .library(name: "DazzleLiteRTLM", targets: ["DazzleLiteRTLM"]),
    ],
    dependencies: [
        // LiteRT-LM community Swift wrapper. Pulled only by the
        // `DazzleLiteRTLM` product — core `Dazzle` consumers do not pay.
        .package(url: "https://github.com/mylovelycodes/LiteRTLM-Swift.git", branch: "main"),
    ],
    targets: [
        // Prebuilt Valkey server + DazzleC modulemap (provides dazzle_ios.h
        // declarations). Built by sdk/ios/build.sh.
        .binaryTarget(
            name: "DazzleBinary",
            path: "Dazzle.xcframework"
        ),

        // Compiles core/platform/dazzle_ios.c (via symlinks under cshim/) so
        // the dazzle_ios_* wrapper functions have implementations at link time.
        .target(
            name: "DazzleSupport",
            path: "cshim",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),

        .target(
            name: "Dazzle",
            dependencies: [
                "DazzleBinary",
                "DazzleSupport",
            ],
            path: "Sources",
            linkerSettings: [
                // libvalkey-server.a embeds hnswlib (C++) + zlib. Mirror the
                // experiment apps' OTHER_LDFLAGS so the xctest binary links
                // cleanly. Without these, the test link fails with a pile
                // of `std::__1::…` undefined symbols.
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),

        // LiteRT-LM adapter. Lives in its own target so the Dazzle core
        // library stays slim. Consumers opt in via:
        //
        //   .product(name: "DazzleLiteRTLM", package: "dazzle")
        //
        // IMPORTANT: on-device you also need a post-build script that
        // re-signs the CLiteRTLM.framework's nested dylib. See the
        // experiment project.yml for the exact incantation.
        .target(
            name: "DazzleLiteRTLM",
            dependencies: [
                "Dazzle",
                .product(name: "LiteRTLMSwift", package: "LiteRTLM-Swift"),
            ],
            path: "Sources-LiteRTLM"
        ),

        .testTarget(
            name: "DazzleTests",
            dependencies: ["Dazzle"],
            path: "Tests/DazzleTests"
        ),
    ]
)
