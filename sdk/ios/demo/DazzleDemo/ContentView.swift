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

struct ContentView: View {
    @State private var isRunning = false
    @State private var commandText = ""
    @State private var output = ""

    private let server = DazzleServer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isRunning ? "Dazzle: Running (port \(server.port))" : "Dazzle: Stopped")
                .font(.headline)

            HStack {
                Button("Start") { startServer() }
                    .disabled(isRunning)
                    .buttonStyle(.borderedProminent)

                Button("Stop") { stopServer() }
                    .disabled(!isRunning)
                    .buttonStyle(.bordered)
            }

            TextField("Command (e.g. PING, SET key value)", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { sendCommand() }
                .disabled(!isRunning)

            Button("Send Command") { sendCommand() }
                .disabled(!isRunning || commandText.isEmpty)
                .buttonStyle(.borderedProminent)

            Text("Output:")
                .font(.subheadline)
                .bold()

            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding()
    }

    private func startServer() {
        DispatchQueue.global().async {
            let ok = server.start()
            DispatchQueue.main.async {
                isRunning = server.isRunning
                if ok {
                    appendOutput("Dazzle started on port \(server.port)")
                    if let pong = server.command("PING") {
                        appendOutput("PING -> \(pong)")
                    }
                } else {
                    appendOutput("Failed to start Dazzle")
                }
            }
        }
    }

    private func stopServer() {
        DispatchQueue.global().async {
            server.stop()
            DispatchQueue.main.async {
                isRunning = server.isRunning
                appendOutput("Dazzle stopped")
            }
        }
    }

    private func sendCommand() {
        let cmd = commandText.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        commandText = ""

        appendOutput("> \(cmd)")
        DispatchQueue.global().async {
            let result = server.command(cmd) ?? "nil"
            DispatchQueue.main.async {
                appendOutput(result)
            }
        }
    }

    private func appendOutput(_ text: String) {
        output += text + "\n"
    }
}
