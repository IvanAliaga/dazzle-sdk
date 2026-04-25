// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

/// Shared setup/teardown for XCTest suites exercising the primitive API.
///
/// Boots a single DazzleServer for the process (the xcframework cannot be
/// torn down and re-created mid-process because of the pthread + setjmp
/// layout in dazzle_ios.c) and flushes the database before each test so
/// cases remain independent.
///
/// Subclasses that need extra modules should override `modules`. Tests skip
/// gracefully if a required module isn't shipped in the xcframework build.
class DazzleTestCase: XCTestCase {

    /// Override to signal a test class needs an optional module. The server
    /// is booted ONCE per process with the union of every class's requested
    /// modules — restarting Valkey on simulator hangs because pthread/event
    /// loop teardown does not complete cleanly, so we never stop it.
    class var modules: Set<DazzleModule> { [] }

    /// Union of modules requested by any DazzleTestCase subclass in this
    /// process. Keep in sync with the concrete test classes.
    private static let allModulesNeeded: Set<DazzleModule> = [.lua, .vectorSearch]

    private static var bootFailed: DazzleError? = nil
    private static var availableModules: Set<DazzleModule> = []

    override func setUpWithError() throws {
        // First call in the process boots the server with the superset. If a
        // module is missing from the xcframework, retry with only the
        // confirmed-available modules so non-optional test classes still run.
        if !DazzleServer.shared.isRunning && Self.bootFailed == nil {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dazzle-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var attempt = Self.allModulesNeeded
            while true {
                do {
                    _ = try DazzleServer.shared.start(config: DazzleConfig(
                        port: 60000,
                        allowPortFallback: true,
                        persistence: .none,
                        dataDir: dir,
                        wipeOnStart: .all,
                        modules: attempt
                    ))
                    Self.availableModules = attempt
                    break
                } catch let DazzleError.moduleUnavailable(mod) {
                    attempt.remove(mod)
                    if attempt.isEmpty || attempt == [.lua] {
                        // fall through once more to try with the minimum
                    }
                } catch {
                    Self.bootFailed = error as? DazzleError
                    throw error
                }
            }
        }

        // Skip cleanly if this class needs a module that did not load.
        let needed = type(of: self).modules
        for mod in needed where !Self.availableModules.contains(mod) {
            throw XCTSkip("module \(mod) not shipped in this xcframework build")
        }

        // Reset state between tests.
        _ = try DazzleServer.shared.client().flushDb()
    }

    var dazzle: Dazzle { DazzleServer.shared.client() }
}
