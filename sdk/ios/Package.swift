// swift-tools-version:5.9
// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// Public Swift Package for the Dazzle SDK. Consumers add this with:
//
//     dependencies: [
//         .package(url: "https://github.com/IvanAliaga/dazzle-sdk.git",
//                  exact: "1.0.0-beta.4"),
//     ]
//
// And then either:
//
//     // Core SDK (zero ML deps).
//     .product(name: "Dazzle", package: "dazzle-sdk"),
//     // Opt-in LiteRT-LM adapter (~80 MB extra).
//     .product(name: "DazzleLiteRTLM", package: "dazzle-sdk"),
//
// Structure:
//   - `DazzleC` module comes from the xcframework's modulemap (binary
//     target downloaded from the matching GitHub Release) and supplies
//     the function declarations + libvalkey-server.a.
//   - `DazzleSupport` is a source C target that compiles dazzle_ios.c
//     so the wrapper `dazzle_ios_*` symbols resolve at link time. Its
//     generated module is never imported — it's a link-only supplier.
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
        // declarations). The xcframework is uploaded as an asset on each
        // tagged GitHub Release; SwiftPM verifies it against the SHA256
        // checksum below before linking.
        //
        // To rebuild for a new tag:
        //     bash sdk/ios/build.sh
        //     cd sdk/ios && zip -r Dazzle.xcframework.zip Dazzle.xcframework
        //     swift package compute-checksum Dazzle.xcframework.zip
        // then upload the zip to the release page and paste the checksum
        // below before tagging.
        //
        // Local development (working from a sibling clone of the repo)
        // can swap in the `path:` form temporarily — keep the URL form
        // as the committed default so external consumers always get a
        // verifiable download.
        .binaryTarget(
            name: "DazzleBinary",
            url: "https://github.com/IvanAliaga/dazzle-sdk/releases/download/v1.0.0-beta.4/Dazzle.xcframework.zip",
            checksum: "ffc1d82854b03dabd8e5e6dcdb5ce04a978e159fa30001ba8daff6914359ce7f"
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
