// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

package dev.dazzle.sdk

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assume.assumeNoException
import org.junit.Before

/**
 * Shared setup/teardown for instrumented tests that exercise the public
 * primitive API.
 *
 * Each concrete test boots a fresh DazzleServer bound to a high port
 * (60000) with no persistence and no extra modules. Tests that need the
 * valkey-search or TFI modules should override [modules] in a subclass.
 *
 * flushDb() runs at the start of every test to keep cases independent
 * even though the server is reused across a single test class.
 */
abstract class DazzleTestBase {

    protected val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    protected val dazzle: Dazzle
        get() = DazzleServer.client()

    /** Override to signal a test class needs an optional module. */
    protected open val modules: Set<DazzleModule> = emptySet()

    companion object {
        /**
         * Superset of every module any DazzleTestBase subclass may need.
         * The server is booted ONCE per process with this set so we never
         * have to stop+restart mid-run — that sequence hangs the direct
         * command pipe on arm64 bionic because static initializers inside
         * the patched Valkey module loader don't reset across runs.
         *
         * Keep in sync with the `modules` override in every subclass.
         */
        private val allModulesNeeded: Set<DazzleModule> =
            setOf(DazzleModule.VectorSearch, DazzleModule.TFI)

        private var availableModules: Set<DazzleModule> = emptySet()
    }

    @Before
    fun bootServer() {
        if (!DazzleServer.isRunning()) {
            // First boot of this process — try the superset; fall back to
            // whatever subset the xcframework/libdazzle actually ships.
            var attempt: Set<DazzleModule> = allModulesNeeded
            while (true) {
                try {
                    DazzleServer.start(
                        context,
                        DazzleConfig(
                            port = 60000,
                            allowPortFallback = true,
                            persistence = DazzlePersistence.None,
                            wipeOnStart = WipeTarget.ALL,
                            modules = attempt,
                        ),
                    )
                    availableModules = attempt
                    break
                } catch (e: DazzleException.ModuleUnavailable) {
                    attempt = attempt - e.module
                    if (attempt.isEmpty()) {
                        assumeNoException(e)
                        return
                    }
                    // else loop and retry with one fewer module
                }
            }
        }

        // Skip cleanly if this class needs a module that did not load.
        for (mod in modules) {
            if (mod !in availableModules) {
                assumeNoException(DazzleException.ModuleUnavailable(mod, mod.label))
                return
            }
        }

        dazzle.flushDb()
    }

    @After
    fun stopServer() {
        // Leave the server running between tests in the same class to cut
        // boot cost; flushDb() in @Before isolates state. A test runner
        // process is short-lived so we don't leak state between test runs.
    }
}
