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

import SwiftUI

@main
struct MultiAgentApp: App {

    init() {
        // Explicit print BEFORE anything else so we can confirm App.init ran
        // at all when inspecting the console stream.
        print("[MultiAgentApp] init() entered")
        NSLog("[MultiAgentApp] init() entered (via NSLog)")

        let env = ProcessInfo.processInfo.environment
        print("[MultiAgentApp] env MODE=\(env["MODE"] ?? "nil") BACKEND=\(env["BACKEND"] ?? "nil") " +
              "AGENTS=\(env["AGENTS"] ?? "nil") DURATION=\(env["DURATION"] ?? "nil")")
        NSLog("[MultiAgentApp] env seen: MODE=%@", env["MODE"] ?? "nil")

        // Auto-run path via env vars:
        //   xcrun devicectl device process launch --device <UDID> \
        //     --environment-variables '{"MODE":"parallel","AGENTS":"8","DURATION":"30","BACKEND":"dazzle-precompute"}' \
        //     io.dazzle.experiment.multiagent
        if env["MODE"] != nil || env["AGENTS"] != nil || env["DURATION"] != nil {
            let opts = MAOptions(
                mode: (env["MODE"] == "parallel" || env["MODE"] == "parallel_reads")
                    ? .parallelReads : .mainThread,
                backend: env["BACKEND"] ?? "dazzle-precompute",
                agents: Int(env["AGENTS"] ?? "") ?? 8,
                durationSec: Int(env["DURATION"] ?? "") ?? 30,
                readPct: Int(env["READ_PCT"] ?? "") ?? 80,
                clusterEnabled: env["CLUSTER_ENABLED"] == "true"
            )
            NSLog("[MultiAgentApp] auto-run: mode=%@ agents=%d dur=%ds backend=%@ cluster=%@",
                  opts.mode.rawValue, opts.agents, opts.durationSec, opts.backend,
                  opts.clusterEnabled ? "true" : "false")
            let mode = opts.mode.rawValue
            // Plain Task (no MainActor) so the bench runs on a background
            // executor instead of the SwiftUI main thread. The MainActor
            // variant we had previously never woke up on devicectl launch —
            // dispatch with a cold start blocked on SwiftUI scene setup.
            Task.detached(priority: .userInitiated) {
                await MultiAgentTest.run(options: opts) { line in
                    NSLog("[auto-run] %@", line)
                }
                MultiAgentApp.writeCompletionMarker(ok: true, message: "multiagent_\(mode)")
                exit(0)
            }
        } else {
            NSLog("[MultiAgentApp] no env vars — UI mode (use Run button)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MultiAgentView()
        }
    }

    private static func writeCompletionMarker(ok: Bool, message: String) {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("experiment_ios_complete.marker")
        let line = "\(Int(Date().timeIntervalSince1970 * 1000)) \(ok ? "ok" : "error") \(message)\n"
        try? line.data(using: .utf8)?.write(to: url)
    }
}
