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
struct BackendsApp: App {

    // The Dazzle server bootstrap is cheap (< 500 ms) and idempotent, so it
    // still lives in `init()` — anything we do before SwiftUI paints can
    // block the UI thread, but Valkey boot is sub-perceptible.
    init() {
        do {
            try DazzleServer.shared.start(config: DazzleConfig(
                port:        6380,
                maxMemory:   "32mb",
                persistence: .none,
                wipeOnStart: [.aof, .rdb],
                modules:     [.vectorSearch]
            ))
            _ = DazzleServer.shared.waitForReady(timeout: 5.0)
        } catch {
            print("[BackendsApp] WARNING: DazzleServer failed to start — \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            // BenchHost drives the automated runs from `.onAppear`, NOT from
            // `BackendsApp.init()`. iOS's start-up watchdog terminates any
            // app whose initial `init` + first paint cycle exceeds ~20 s;
            // StorageOnlyTest finishes in < 1 s so it escaped the deadline,
            // but VectorBenchmark at N=10 000 × dim=384 blows past it and
            // gets SIGKILL'd with no JSON written. Moving the bench to a
            // post-paint `Task.detached` lets the bench run for minutes
            // without tripping the watchdog — the UI is visible, the
            // runtime is happy, and we only `exit(0)` once the benchmark
            // has written its JSON + marker.
            BenchHost()
        }
    }
}

/// View that owns the automated bench. On appear, it dispatches to
/// `StorageOnlyTest` or `VectorBenchmark` based on environment variables
/// / launch arguments, then terminates the process when the bench has
/// produced its JSON + completion marker.
private struct BenchHost: View {
    @State private var status: String = "booting…"
    @State private var started: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Dazzle Backends").font(.title2).bold()
            Text(status)
                .font(.system(.body, design: .monospaced))
                .padding()
                .multilineTextAlignment(.center)
        }
        .task(priority: .userInitiated) {
            // `.task` fires once the view is on screen — this is past the
            // iOS start-up watchdog, so the bench can take as long as it
            // needs without iOS considering the app hung.
            guard !started else { return }
            started = true
            await runAutomationIfRequested()
        }
    }

    // MARK: - Automation dispatch

    private func runAutomationIfRequested() async {
        let env  = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        func argValue(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let autoBackend = env["BACKEND"] ?? argValue("--backend")
        let autoStorage = env["STORAGE_ONLY"] == "true" || args.contains("--storage-only")
        let autoVector  = env["VECTOR_BENCH"] == "true" || args.contains("--vector-bench")

        if autoVector {
            await runVectorBench(
                preset: env["VECTOR_CONFIGS"] ?? argValue("--configs") ?? "")
            return
        }
        if let backendName = autoBackend, autoStorage {
            await runStorageOnly(backend: backendName)
            return
        }
        status = "no automation env var set — manual mode"
    }

    // MARK: - Bench runners

    @MainActor
    private func runStorageOnly(backend: String) async {
        status = "storage-only bench: \(backend)…"
        await Task.detached(priority: .userInitiated) {
            StorageOnlyTest.run(backendName: backend)
        }.value
        writeMarker(ok: true, message: "storage_only_\(backend)")
        status = "storage-only done — exiting"
        // Small grace period so the marker fsyncs to disk.
        try? await Task.sleep(nanoseconds: 200_000_000)
        exit(0)
    }

    @MainActor
    private func runVectorBench(preset: String) async {
        // Map preset string → configs.
        let configs: [VectorBenchmark.Config]
        switch preset {
        case "paper200":
            configs = [VectorBenchmark.Config(dim: 384, nDocs: 200)]
        case "headline":
            configs = [VectorBenchmark.Config(dim: 384, nDocs: 10_000)]
        case "paper384":
            // 3 rows at dim=384 — mirrors the published Android table.
            configs = [
                VectorBenchmark.Config(dim: 384, nDocs: 500),
                VectorBenchmark.Config(dim: 384, nDocs: 2_000),
                VectorBenchmark.Config(dim: 384, nDocs: 10_000),
            ]
        case "paper384_scale":
            // iOS parity sweep for Table 4-style vector rows.
            configs = [
                VectorBenchmark.Config(dim: 384, nDocs: 200),
                VectorBenchmark.Config(dim: 384, nDocs: 1_000),
                VectorBenchmark.Config(dim: 384, nDocs: 5_000),
                VectorBenchmark.Config(dim: 384, nDocs: 20_000),
            ]
        case "smoke":
            configs = [VectorBenchmark.Config(dim: 16, nDocs: 500)]
        default:
            configs = VectorBenchmark.DEFAULT_CONFIGS
        }

        status = "vector bench: \(configs.count) configs queued"
        await Task.detached(priority: .userInitiated) {
            VectorBenchmark.run(configs: configs)
        }.value
        writeMarker(ok: true, message: "vector_bench")
        status = "vector bench done — exiting"
        try? await Task.sleep(nanoseconds: 200_000_000)
        exit(0)
    }

    // MARK: - Marker helper

    private func writeMarker(ok: Bool, message: String) {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("experiment_ios_complete.marker")
        let line = "\(Int(Date().timeIntervalSince1970 * 1000)) "
                 + "\(ok ? "ok" : "error") \(message)\n"
        try? line.data(using: .utf8)?.write(to: url)
    }
}
