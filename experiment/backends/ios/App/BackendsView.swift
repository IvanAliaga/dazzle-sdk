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

/// Interactive UI for running StorageOnlyTest against individual backends.
/// Use this to develop and validate new backend implementations without
/// loading the full LLM experiment.
struct BackendsView: View {

    @State private var selectedBackend = "dazzle"
    @State private var log = ""
    @State private var isRunning = false

    private let backends = [
        "dazzle", "dazzle-lua", "dazzle-pipeline",
        "dazzle-hfe", "dazzle-hll", "dazzle-precompute",
        "dazzle-vector",
        "valkey", "sqlite", "inmemory",
    ]

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {

                Picker("Backend", selection: $selectedBackend) {
                    ForEach(backends, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)

                Button {
                    run(backend: selectedBackend)
                } label: {
                    Label("Run Storage Test", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .padding(.horizontal)

                GroupBox {
                    ScrollView {
                        Text(log.isEmpty ? "Tap Run to start." : log)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                } label: {
                    Label("Log", systemImage: "terminal.fill").font(.headline)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Dazzle Backends")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func run(backend: String) {
        isRunning = true
        log = "Running \(backend)…\n"
        Task.detached(priority: .userInitiated) {
            // Capture printed output by redirecting — we use a simple log prefix
            // approach instead: StorageOnlyTest prints via print(), which goes to
            // the console. For the UI we just show start/done.
            if backend.lowercased() == "dazzle-vector" {
                    VectorSearchTest.run()
                } else {
                    StorageOnlyTest.run(backendName: backend)
                }
            await MainActor.run {
                self.log += "Done. Check Console or Documents/ for JSON results.\n"
                self.isRunning = false
            }
        }
    }
}

#if DEBUG
struct BackendsView_Previews: PreviewProvider {
    static var previews: some View { BackendsView() }
}
#endif
