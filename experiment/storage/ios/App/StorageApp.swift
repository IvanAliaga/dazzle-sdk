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

@main
struct StorageApp: App {

    init() {
        // Start embedded Dazzle server for backends that need it.
        // tcpEnabled is on so the Valkey baseline backend can talk RESP
        // over a real TCP loopback socket (same path as a Lettuce/Jedis-
        // style mobile client). Dazzle backends still take the in-process
        // pipe route — both transports coexist on the same server.
        do {
            try DazzleServer.shared.start(config: DazzleConfig(
                tcpEnabled:  true,
                port:        6380,
                maxMemory:   "32mb",
                persistence: .none,
                wipeOnStart: [.aof, .rdb]
            ))
            _ = DazzleServer.shared.waitForReady(timeout: 5.0)
        } catch {
            print("[StorageApp] WARNING: DazzleServer failed to start — \(error)")
        }

        // Automation hook: STORAGE_ONLY=true BACKEND=<name> → run and exit.
        //   xcrun devicectl device process launch --device <UDID> \
        //     --environment-variables '{"STORAGE_ONLY":"true","BACKEND":"dazzle"}' \
        //     io.dazzle.experiment.storage
        let env = ProcessInfo.processInfo.environment
        if env["STORAGE_ONLY"] == "true" {
            let backendName = env["BACKEND"] ?? "dazzle"
            StorageOnlyTest.run(backendName: backendName)
            writeCompletionMarker(ok: true, message: "storage_only_\(backendName)")
            exit(0)
        }
        if env["SCALE_BENCHMARK"] == "true" {
            let backendName = env["BACKEND"] ?? "dazzle-precompute"
            let counts = parseScaleCounts(env["SCALE_COUNTS"] ?? "200,1000,5000,20000")
            StorageOnlyTest.runScale(backendName: backendName, readingCounts: counts)
            writeCompletionMarker(ok: true, message: "scale_benchmark_\(backendName)")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            StorageView()
        }
    }

    private func writeCompletionMarker(ok: Bool, message: String) {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let line = "\(ts) \(ok ? "ok" : "error") \(message)\n"
        // Per-run marker so an automation harness can confirm a fresh
        // process actually executed (the legacy single-name marker would
        // be silently overwritten on every launch and could not
        // distinguish "ran" from "was never re-spawned").
        let perRunURL = docs.appendingPathComponent("experiment_ios_complete_\(message)_\(ts).marker")
        try? line.data(using: .utf8)?.write(to: perRunURL)
        // Legacy marker for backwards compatibility with older harnesses.
        let legacyURL = docs.appendingPathComponent("experiment_ios_complete.marker")
        try? line.data(using: .utf8)?.write(to: legacyURL)
    }

    private func parseScaleCounts(_ csv: String) -> [Int] {
        let items = csv.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return items.isEmpty ? [200, 1000, 5000, 20000] : items
    }
}
