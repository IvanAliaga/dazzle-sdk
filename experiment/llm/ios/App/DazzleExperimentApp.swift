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
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI
import UIKit
// DazzleServer is compiled directly into the target (see project.yml sources)

@main
struct DazzleExperimentApp: App {

    init() {
        // Start embedded Valkey configured for the experiment:
        //   - Ephemeral (no persistence), so runs are fully reproducible
        //   - Wipe any leftover AOF/RDB from previous runs before boot
        //   - Dedicated port 6380 to avoid any conflict with a system
        //     Redis/Valkey if the developer runs one
        //   - Relatively tight memory limit
        //
        // Everything the pipeline needs (flush, retrieval, agent decisions)
        // goes through the typed DazzleConfig; we no longer have to mkdir /
        // rm -rf manually.
        do {
            try DazzleServer.shared.start(config: DazzleConfig(
                port:        6380,
                maxMemory:   "32mb",
                persistence: .none,
                wipeOnStart: [.aof, .rdb],
                modules:     [.lua, .vectorSearch]
            ))
            _ = DazzleServer.shared.waitForReady(timeout: 5.0)
            print("[DazzleExperiment] Embedded server ready on port 6380 (no persistence, wiped)")
        } catch {
            print("[DazzleExperiment] WARNING: embedded server failed to start — \(error)")
        }

        // Storage-only automation: run immediately from init() (before
        // SwiftUI renders) so we don't depend on onAppear timing.
        let env = ProcessInfo.processInfo.environment
        if env["STORAGE_ONLY"] == "true" {
            let backendName = env["BACKEND"] ?? "dazzle-precompute"
            print("[AutoRun] STORAGE_ONLY=true BACKEND=\(backendName)")
            StorageOnlyTest.run(backendName: backendName)
            print("[AutoRun] done — exiting")
            exit(0)
        }
        // §5.9 RAG E2E auto-run on iOS — same JSON shape as the Android
        // bench, mirrors `RagE2EBench.run` from `experiment/backends/
        // android/core/RagE2EBench.kt`. Launch with:
        //   xcrun devicectl device process launch \
        //     --environment-variables RAG_E2E=true \
        //     io.dazzle.experiment
        // Optional `MAX_QUERIES=N` to bound the slice for smoke tests.
        if env["RAG_E2E"] == "true" {
            print("[AutoRun] RAG_E2E=true — launching iOS §5.9 bench on background queue")
            // Detach so SwiftUI's main runloop returns within iOS's 20-s
            // launch-watchdog (0x8BADF00D). The bench will run for
            // 25-50 min on A14, write its JSON to Documents/, and
            // `exit(0)` itself when done. The host app stays in
            // foreground (idle UI) so jetsam doesn't kill it.
            DispatchQueue.global(qos: .userInitiated).async {
                RagE2EBench.run()
                print("[AutoRun] RAG_E2E done — exiting")
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // When RAG_E2E=true the bench runs on a detached queue from
            // init(); rendering ExperimentView() would try to load the
            // Gemma weights (which are not pushed to this device for the
            // §5.9 RAG bench) and either fatal-error or block the main
            // thread. A placeholder view keeps the app foregrounded so
            // jetsam doesn't kill the long-running bench.
            if ProcessInfo.processInfo.environment["RAG_E2E"] == "true" {
                Text("RagE2EBench running — see console / Documents/")
                    .padding()
                    .onAppear {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
            } else {
                ExperimentView()
            }
        }
    }
}
