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

// ─────────────────────────────────────────────────────────────────────────────
// ExperimentView  —  main UI for the Sequential Monitoring Agent experiment
// Model: Gemma 4 E2B (gemma-4-E2B-it.litertlm, ~2.41 GB, place in Documents/)
// Runtime: LiteRT-LM (community Swift wrapper), same as the Android experiment.
// ─────────────────────────────────────────────────────────────────────────────
// Wrapped in `extension Paper2` so the struct coexists with the main baseline
// (App/ExperimentView.swift) and the Valkey 8 precursor variant.
extension Paper2 {

struct ExperimentView: View {

    @StateObject private var pipeline = ExperimentPipelineIoTPaper2()
    @State private var modelPath = ""
    @State private var showModelPicker = false
    @State private var selectedBackend = Self.defaultBackend

    // Backends available in the DazzleExperiment target. Order matters — the
    // picker shows them in this order, and the first entry is the default
    // retrieval technique (dazzle-precompute: fastest context retrieval).
    static let availableBackends: [String] = [
        "dazzle-precompute",
        "dazzle-vector",
        "dazzle",
        "dazzle-pipeline",
        "dazzle-hfe",
        "dazzle-hll",
        "dazzle-lua",
        "valkey",
        "sqlite",
        "inmemory",
    ]
    static let defaultBackend = "dazzle-precompute"

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    headerSection
                    backendPickerSection
                    modelPickerSection
                    controlSection

                    if pipeline.isRunning || pipeline.progress > 0 {
                        progressSection
                    }

                    if let results = pipeline.results {
                        metricsSection(results)
                        synthesisSection(results)
                    }

                    if !pipeline.log.isEmpty {
                        logSection
                    }
                }
                .padding()
            }
            .navigationTitle("Dazzle × Gemma Experiment")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            modelPath = defaultModelPath()
            maybeStartAutoRun()
        }
    }

    // ── Automation hook ──────────────────────────────────────────────────────
    //
    // When the app is launched via
    //   xcrun devicectl device process launch --device <UDID> \
    //       --environment-variables '{"RUN_COUNT":"1"}' dev.dazzle.experiment
    //
    // we run the pipeline once, write the completion marker, and call exit(0)
    // so the next devicectl launch starts from a fresh process.
    //
    // Running multiple experiments back-to-back inside a single process
    // segfaults in LiteRT-LM's native engine: creating a second `Engine`
    // instance in the same process hits a memtest assertion and SIGSEGVs
    // (verified on Android Moto G35 — the iOS binary is the same runtime
    // published under a different wrapper, so we play it safe on both). The
    // driver script (research/scripts/run_experiment.sh) now loops N times externally,
    // killing and relaunching the app per run, instead of asking this code
    // to loop internally.
    private func maybeStartAutoRun() {
        let env = ProcessInfo.processInfo.environment
        let backendName = env["BACKEND"] ?? Self.defaultBackend
        let storageOnly = env["STORAGE_ONLY"] == "true"
        print("[AutoRun] env STORAGE_ONLY=\(env["STORAGE_ONLY"] ?? "nil") BACKEND=\(backendName) RUN_COUNT=\(env["RUN_COUNT"] ?? "nil")")

        // Storage-only test: no Gemma, just backend benchmarking
        if storageOnly {
            Task { @MainActor in
                pipeline.log += "\n══════════ STORAGE-ONLY TEST: \(backendName) ══════════\n"
                StorageOnlyTest.run(backendName: backendName)
                writeAutoRunMarker(ok: true, message: "storage_only_\(backendName)")
                exit(0)
            }
            return
        }

        guard env["RUN_COUNT"] != nil else { return }

        let path = modelPath
        Task { @MainActor in
            var failed: String? = nil
            pipeline.log += "\n══════════ AUTO RUN (\(backendName)) ══════════\n"
            await pipeline.run(modelPath: path, backendName: backendName)
            if pipeline.results == nil {
                failed = "pipeline produced no results"
            }
            writeAutoRunMarker(ok: failed == nil, message: failed ?? "ok")
            exit(0)
        }
    }

    private func writeAutoRunMarker(ok: Bool, message: String) {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("experiment_ios_complete.marker")
        let line = "\(Int(Date().timeIntervalSince1970 * 1000)) \(ok ? "ok" : "error") \(message)\n"
        try? line.data(using: .utf8)?.write(to: url)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sequential Monitoring Agent v2")
                .font(.headline)
            Text("20 checkpoints · 3 tasks · 400 readings · 10 fault events")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Task 1: Detection  |  Task 2: Prediction  |  Task 3: Report")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var backendPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Storage backend").font(.subheadline).bold()
            Picker("Backend", selection: $selectedBackend) {
                ForEach(Self.availableBackends, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .disabled(pipeline.isRunning)
            Text("Default is dazzle-precompute (best retrieval). Switch to compare how context quality affects token cost and synthesis score.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var modelPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model path").font(.subheadline).bold()
            HStack {
                TextField("Gemma .litertlm", text: $modelPath)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("Browse") { showModelPicker = true }
                    .buttonStyle(.bordered)
            }
            if !modelPath.isEmpty {
                let exists = FileManager.default.fileExists(atPath: modelPath)
                Label(exists ? "File found" : "File not found",
                      systemImage: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(exists ? .green : .red)
            }
        }
        .fileImporter(isPresented: $showModelPicker,
                      allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                // Security-scoped access
                _ = url.startAccessingSecurityScopedResource()
                modelPath = url.path
            }
        }
    }

    private var controlSection: some View {
        HStack {
            Button {
                // Env var wins if present (scripted runs); otherwise the UI
                // picker drives the backend so the tester can flip between
                // Dazzle variants and disk-backed backends without rebuilding.
                let envBackend = ProcessInfo.processInfo.environment["BACKEND"]
                let backend = envBackend ?? selectedBackend
                Task { await pipeline.run(modelPath: modelPath, backendName: backend) }
            } label: {
                Label("Run Experiment", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pipeline.isRunning || modelPath.isEmpty)

            if pipeline.isRunning {
                Button {
                    // future: pipeline.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .disabled(true)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Progress")
                    .font(.subheadline).bold()
                Spacer()
                Text("\(pipeline.progress) / \(pipeline.total)")
                    .font(.caption).foregroundColor(.secondary)
            }
            ProgressView(value: Double(pipeline.progress),
                         total: Double(max(1, pipeline.total)))
            if pipeline.isRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text("Running…").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Results

    private func metricsSection(_ r: ExperimentResults) -> some View {
        let tpCPs = r.checkpoints.filter { $0.windowHasAnomaly }
        let tnCPs = r.checkpoints.filter { !$0.windowHasAnomaly }
        let recallA = Double(tpCPs.filter { $0.stateless.detected }.count) / Double(max(1, tpCPs.count))
        let recallB = Double(tpCPs.filter { $0.augmented.detected }.count) / Double(max(1, tpCPs.count))
        let fprA    = Double(tnCPs.filter { $0.stateless.detected }.count) / Double(max(1, tnCPs.count))
        let fprB    = Double(tnCPs.filter { $0.augmented.detected }.count) / Double(max(1, tnCPs.count))
        let avgLat  = r.checkpoints.map { $0.backendLatencyUs }.reduce(0, +) / Double(r.checkpoints.count)
        let preds   = r.checkpoints.compactMap { $0.prediction }
        let predAcc = preds.isEmpty ? 0.0 : Double(preds.filter { $0.predictionCorrect }.count) / Double(preds.count)
        let predRec = Double(preds.filter { $0.nextWindowHasFault && $0.predictionCorrect }.count) /
                      Double(max(1, preds.filter { $0.nextWindowHasFault }.count))

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {

                Text("Task 1 — Fault Detection (\(tpCPs.count) fault CPs)")
                    .font(.subheadline).bold()
                metricRow(label: "Recall",
                          a: pct(recallA), b: pct(recallB),
                          delta: pct(recallB - recallA),
                          positive: recallB >= recallA)
                metricRow(label: "False Positive Rate",
                          a: pct(fprA), b: pct(fprB),
                          delta: pct(fprB - fprA),
                          positive: fprB <= fprA)

                Divider()

                Text("Task 2 — Risk Prediction (augmented only)")
                    .font(.subheadline).bold()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accuracy").font(.caption).foregroundColor(.secondary)
                        Text(pct(predAcc)).font(.system(.caption, design: .monospaced)).bold()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fault recall").font(.caption).foregroundColor(.secondary)
                        Text(pct(predRec)).font(.system(.caption, design: .monospaced)).bold()
                    }
                }

                Divider()

                Text("Task 3 — Maintenance Report (max 3)")
                    .font(.subheadline).bold()
                HStack {
                    scoreBar(label: "Stateless", score: r.reportStateless.consistencyScore, max: 3)
                    scoreBar(label: "Augmented", score: r.reportAugmented.consistencyScore, max: 3)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Patterns").font(.caption2).foregroundColor(.secondary)
                        Text("\(r.reportStateless.patternsIdentified)/5 → \(r.reportAugmented.patternsIdentified)/5")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                Divider()

                HStack {
                    Image(systemName: "bolt.fill").foregroundColor(.yellow)
                    Text("Retrieval latency: \(String(format: "%.1f", avgLat)) µs avg")
                        .font(.caption)
                }

                checkpointGrid(r.checkpoints)
            }
        } label: {
            Label("Experiment Results", systemImage: "chart.bar.fill")
                .font(.headline)
        }
    }

    private func metricRow(label: String, a: String, b: String,
                           delta: String, positive: Bool) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 120, alignment: .leading)
            Text("A: \(a)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Text("B: \(b)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
            Spacer()
            Text("Δ\(delta)")
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundColor(positive ? .green : .red)
        }
    }

    private func scoreBar(label: String, score: Int, max: Int) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<max, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < score ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 28, height: 20)
                        .overlay(
                            Text(i < score ? "✓" : "✗")
                                .font(.system(size: 10))
                                .foregroundColor(i < score ? .white : .gray)
                        )
                }
            }
            Text("\(score)/\(max)").font(.caption2.bold())
        }
    }

    private func checkpointGrid(_ cps: [CheckpointResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Checkpoint detail").font(.caption).bold()
            HStack(spacing: 0) {
                Text(" CP ").frame(width: 36)
                Text("Min").frame(width: 36)
                Text("GT").frame(width: 28)
                Text(" A ").frame(width: 28)
                Text(" B ").frame(width: 28)
                Spacer()
                Text("Lat(µs)").frame(width: 60)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)

            ForEach(cps, id: \.cpIndex) { cp in
                HStack(spacing: 0) {
                    Text("\(cp.cpIndex + 1)").frame(width: 36)
                    Text("\(cp.minute)").frame(width: 36)
                    boolDot(cp.windowHasAnomaly, color: .orange).frame(width: 28)
                    boolDot(cp.stateless.detected, color: .blue).frame(width: 28)
                    boolDot(cp.augmented.detected, color: .green).frame(width: 28)
                    Spacer()
                    Text(String(format: "%.0f", cp.backendLatencyUs))
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .background(cp.windowHasAnomaly == cp.augmented.detected &&
                            cp.windowHasAnomaly != cp.stateless.detected
                            ? Color.green.opacity(0.08) : Color.clear)
            }
        }
    }

    private func boolDot(_ v: Bool, color: Color) -> some View {
        Image(systemName: v ? "circle.fill" : "circle")
            .font(.system(size: 9))
            .foregroundColor(v ? color : .gray.opacity(0.4))
    }

    private func synthesisSection(_ r: ExperimentResults) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                synthesisDetail(label: "Stateless",
                                score: r.synthesis.statelessScore,
                                raw: r.synthesis.statelessRaw)
                Divider()
                synthesisDetail(label: "Augmented",
                                score: r.synthesis.augmentedScore,
                                raw: r.synthesis.augmentedRaw)
            }
        } label: {
            Label("Synthesis (CP10)", systemImage: "doc.text.fill")
                .font(.headline)
        }
    }

    private func synthesisDetail(label: String, score: SynthesisScore, raw: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).bold()
            HStack {
                checkLabel("Count ±2",  ok: score.anomalyCountCorrect,
                           detail: score.anomalyCountExtracted.map { "\($0)" } ?? "?")
                checkLabel("Max±1.5°C", ok: score.maxTempCorrect,
                           detail: score.maxTempExtracted.map { String(format: "%.1f", $0) } ?? "?")
                checkLabel("Dropout",   ok: score.dropoutMentioned, detail: "")
            }
            DisclosureGroup("Raw response") {
                ScrollView {
                    Text(raw.isEmpty ? "(no response)" : raw)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .font(.caption)
        }
    }

    private func checkLabel(_ name: String, ok: Bool, detail: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
            Text(name).font(.system(size: 9))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            }
        }
    }

    private var logSection: some View {
        GroupBox {
            ScrollView {
                Text(pipeline.log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        } label: {
            Label("Log", systemImage: "terminal.fill").font(.headline)
        }
    }

    // MARK: - Helpers

    private func pct(_ v: Double) -> String { String(format: "%+.0f%%", v * 100) }

    private func defaultModelPath() -> String {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0].path
        // Gemma 4 E2B — same model + runtime (LiteRT-LM) as the Android experiment.
        // Download: huggingface-cli download litert-community/gemma-4-E2B-it-litert-lm \
        //             gemma-4-E2B-it.litertlm --local-dir ~/Downloads/
        return "\(docs)/\(GemmaEngine.defaultModelFilename)"
    }
}

// MARK: - Preview

#if DEBUG
struct ExperimentView_Previews: PreviewProvider {
    static var previews: some View {
        ExperimentView()
    }
}
#endif

} // extension Paper2
