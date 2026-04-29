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

/// Storage-only benchmark UI — runs StorageOnlyTest against any backend
/// without loading Gemma. Use this to compare backend performance or
/// validate a backend before running the full LLM experiment.
struct StorageView: View {

    @State private var selectedBackend = "dazzle"
    @State private var log = ""
    @State private var isRunning = false

    private let backends = [
        "dazzle", "dazzle-lua", "dazzle-pipeline",
        "dazzle-hfe", "dazzle-hll", "dazzle-precompute",
        "dazzle-vector",
        "valkey", "sqlite", "sqlite-optimized", "lmdb", "rocksdb", "inmemory",
    ]

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage-only benchmark")
                        .font(.headline)
                    Text("200 readings · 10 checkpoints · no Gemma")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                Picker("Backend", selection: $selectedBackend) {
                    ForEach(backends, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)

                HStack {
                    Button {
                        runStorageOnly(backend: selectedBackend)
                    } label: {
                        Label("Run Storage Test", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)

                    Button {
                        runAll()
                    } label: {
                        Label("Run All", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }
                .padding(.horizontal)

                GroupBox {
                    ScrollView {
                        Text(log.isEmpty ? "Select a backend and tap Run." : log)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                } label: {
                    Label("Log", systemImage: "terminal.fill").font(.headline)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Dazzle Storage")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func runStorageOnly(backend: String) {
        isRunning = true
        log = "Running \(backend)…\n"
        Task.detached(priority: .userInitiated) {
            StorageOnlyTest.run(backendName: backend)
            await MainActor.run {
                self.log += "Done. Check Console or Documents/ for JSON.\n"
                self.isRunning = false
            }
        }
    }

    private func runAll() {
        let all = backends
        isRunning = true
        log = "Running all \(all.count) backends…\n"
        Task.detached(priority: .userInitiated) {
            for backend in all {
                await MainActor.run { self.log += "\n── \(backend) ──\n" }
                StorageOnlyTest.run(backendName: backend)
            }
            await MainActor.run {
                self.log += "\nAll done. Check Documents/ for JSON results.\n"
                self.isRunning = false
            }
        }
    }
}

#if DEBUG
struct StorageView_Previews: PreviewProvider {
    static var previews: some View { StorageView() }
}
#endif
