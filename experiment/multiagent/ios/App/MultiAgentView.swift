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

struct MultiAgentView: View {

    @State private var selectedMode: MAMode = .mainThread
    @State private var selectedBackend = "dazzle-precompute"
    @State private var agents: Int = 8
    @State private var durationSec: Int = 30
    @State private var readPct: Int = 80
    @State private var clusterEnabled: Bool = false

    @State private var log: String = ""
    @State private var isRunning: Bool = false

    private let backends: [String] = [
        "dazzle-precompute", "dazzle", "dazzle-pipeline",
        "dazzle-hfe", "dazzle-hll", "dazzle-lua",
        "valkey", "sqlite", "inmemory",
    ]

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {

                VStack(alignment: .leading, spacing: 4) {
                    Text("Plan 02 — Multi-Agent Benchmark")
                        .font(.headline)
                    Text("K concurrent Swift Tasks × 80/20 reads/writes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                GroupBox("Config") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mode", selection: $selectedMode) {
                            Text("MainThread (baseline)").tag(MAMode.mainThread)
                            Text("ParallelReads (Plan 02)").tag(MAMode.parallelReads)
                        }
                        Picker("Backend", selection: $selectedBackend) {
                            ForEach(backends, id: \.self) { Text($0) }
                        }
                        Stepper("Agents: \(agents)", value: $agents, in: 1...32)
                            .font(.caption)
                        Stepper("Duration: \(durationSec)s", value: $durationSec, in: 5...120)
                            .font(.caption)
                        Stepper("Read %: \(readPct)", value: $readPct, in: 0...100, step: 10)
                            .font(.caption)
                        Toggle("cluster-enabled (Camino B)", isOn: $clusterEnabled)
                            .font(.caption)
                    }
                }
                .padding(.horizontal)

                Button {
                    startBench()
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .padding(.horizontal)

                GroupBox {
                    ScrollView {
                        Text(log.isEmpty ? "Configure and tap Run." : log)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                } label: {
                    Label("Log", systemImage: "terminal.fill").font(.headline)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Dazzle MultiAgent")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func startBench() {
        let opts = MAOptions(
            mode: selectedMode,
            backend: selectedBackend,
            agents: agents,
            durationSec: durationSec,
            readPct: readPct,
            clusterEnabled: clusterEnabled
        )
        isRunning = true
        log = "Starting…\n"
        Task.detached(priority: .userInitiated) {
            await MultiAgentTest.run(options: opts) { line in
                Task { @MainActor in
                    self.log += line + "\n"
                }
            }
            await MainActor.run { self.isRunning = false }
        }
    }
}

#if DEBUG
struct MultiAgentView_Previews: PreviewProvider {
    static var previews: some View { MultiAgentView() }
}
#endif
