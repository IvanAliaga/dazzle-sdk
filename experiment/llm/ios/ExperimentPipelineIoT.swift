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

import Foundation
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// ExperimentPipelineIoT v2 — Three-Task Sequential Monitoring Agent
//
//   Task 1 — DETECTION   : Fault classification per checkpoint.
//             Threshold crossing is pre-computed; the agent classifies
//             severity. Without memory: conservative. With memory: similar
//             past faults calibrate severity.
//
//   Task 2 — PREDICTION  : Risk forecast for the NEXT 20-minute window.
//             Without memory: random guess. With vector memory: agent
//             recalls similar sensor profiles that preceded faults.
//
//   Task 3 — REPORT      : Cumulative maintenance report at session end.
//             Without Dazzle: agent hallucinates statistics.
//             With Dazzle (precompute KV): accurate counts, ranges, timeline.
//
// Dataset: dataset_iot_valkey8.json — 400 readings, 20 checkpoints, 10 fault events
// (5 pattern types × 2 occurrences) designed to stress memory recall.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Result types

struct AnomalyDecision {
    let detected:  Bool
    let severity:  String
    let trend:     String
    let rawJson:   String
}

struct RiskPrediction {
    let riskPct:           Int       // 0–100
    let riskLevel:         String    // low / medium / high
    let rawJson:           String
    let nextWindowHasFault: Bool
    let predictionCorrect: Bool
}

struct CheckpointResult {
    let cpIndex:          Int
    let minute:           Int
    let windowHasAnomaly: Bool
    let stateless:        AnomalyDecision
    let augmented:        AnomalyDecision
    let prediction:       RiskPrediction?
    let backendLatencyUs: Double
    let inferenceMsA:     Double
    let inferenceMsB:     Double
    let promptTokensA:    Int
    let promptTokensB:    Int
    let promptTokensPred: Int
    var contextBlock:     String = ""
}

struct ReportScore {
    let faultCountCorrect: Bool
    let maxTempCorrect:    Bool
    let minTempCorrect:    Bool
    let patternsIdentified: Int   // 0–5 keywords found
    let consistencyScore:  Int    // 0–3
    let raw:               String
}

struct GroundTruth {
    let totalAnomalies: Int
    let maxTemp:        Double
    let minTemp:        Double
    let anomalyMinutes: [Int]
}

// Legacy synthesis types kept for cross-run JSON comparability
struct SynthesisScore {
    let anomalyCountCorrect:   Bool
    let maxTempCorrect:        Bool
    let dropoutMentioned:      Bool
    let anomalyCountExtracted: Int?
    let maxTempExtracted:      Double?
    var total: Int { [anomalyCountCorrect, maxTempCorrect, dropoutMentioned].filter { $0 }.count }
}

struct SynthesisResult {
    let statelessRaw:   String
    let augmentedRaw:   String
    let statelessScore: SynthesisScore
    let augmentedScore: SynthesisScore
}

struct ExperimentResults {
    let type:            String
    let device:          String
    let model:           String
    let backend:         String
    let platform:        String
    let timestamp:       String
    let deviceInfo:      [String: Any]
    let batteryBefore:   [String: Any]?
    let batteryAfter:    [String: Any]?
    let checkpoints:     [CheckpointResult]
    let reportStateless: ReportScore
    let reportAugmented: ReportScore
    let synthesis:       SynthesisResult     // legacy field
    let groundTruth:     GroundTruth
}

// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ExperimentPipelineIoT: ObservableObject {

    @Published var progress:  Int    = 0
    @Published var total:     Int    = 0
    @Published var log:       String = ""
    @Published var isRunning: Bool   = false
    @Published var results:   ExperimentResults?

    private static let FAULT_HIGH = 28.0
    private static let FAULT_LOW  =  5.0

    // MARK: - Run

    func run(modelPath: String, backendName: String = "dazzle-precompute") async {
        isRunning = true
        progress  = 0
        log       = ""
        results   = nil

        do {
            // Restart server with vectorSearch module when needed
            ensureServer(for: backendName)

            let dataset = try SensorDataset.load()
            let numCPs  = dataset.checkpointIndices.count
            total = numCPs * 3 + 2

            let storage = createBackend(name: backendName)
            appendLog("Backend: \(storage.backendName)")

            let batteryBefore = SystemSnapshot.batterySnapshot()

            appendLog("Loading Gemma 4 E2B (LiteRT-LM)…")
            let gemma = try GemmaEngine(modelPath: modelPath)
            try await gemma.warmUp()
            appendLog("Model ready. Starting experiment.\n")

            storage.flush()

            // ── Condition A: Stateless detection ──────────────────────────
            appendLog("── Task 1A: Stateless fault detection ──")
            var statelessDecisions: [AnomalyDecision] = []
            var inferenceMsA:  [Double] = []
            var promptTokensA: [Int]    = []

            for cpIdx in 0..<numCPs {
                let cpReading = dataset.readings[dataset.checkpointIndices[cpIdx]]
                let window    = dataset.window(forCheckpoint: cpIdx)
                appendLog("[A] CP\(cpIdx + 1)/\(numCPs) min=\(cpReading.minute)")

                let prompt = buildDetectionPrompt(reading: cpReading, window: window, context: nil)
                promptTokensA.append(Self.estimateTokens(prompt))
                let t0  = Date()
                let raw = (try? await gemma.generate(prompt: prompt)) ?? fallbackDetection
                inferenceMsA.append(Date().timeIntervalSince(t0) * 1000)
                statelessDecisions.append(parseAnomalyDecision(raw))
                progress += 1
            }

            // ── Condition B: Augmented detection + prediction ─────────────
            appendLog("\n── Task 1B + 2: Augmented detection & prediction ──")
            var augmentedDecisions: [AnomalyDecision] = []
            var predictions:        [RiskPrediction?]  = []
            var backendLatencies:   [Double] = []
            var inferenceMsB:       [Double] = []
            var promptTokensB:      [Int]    = []
            var promptTokensPred:   [Int]    = []
            var inferenceMsPred:    [Double] = []
            var contextBlocks:      [String] = []
            var lastIngested = -1

            for cpIdx in 0..<numCPs {
                let cpEndIdx  = dataset.checkpointIndices[cpIdx]
                let cpReading = dataset.readings[cpEndIdx]
                appendLog("[B] CP\(cpIdx + 1)/\(numCPs) min=\(cpReading.minute)")

                for i in (lastIngested + 1)...cpEndIdx {
                    storage.ingest(SensorReading(
                        minute:    dataset.readings[i].minute,
                        tempC:     dataset.readings[i].tempC,
                        humidity:  dataset.readings[i].humidity,
                        anomalous: dataset.readings[i].anomalous
                    ))
                }
                lastIngested = cpEndIdx

                let latencyUs   = storage.measureRetrievalLatency(currentMinute: cpReading.minute)
                backendLatencies.append(latencyUs)

                let context = storage.buildContextBlock(currentMinute: cpReading.minute)
                contextBlocks.append(context)
                let window  = dataset.window(forCheckpoint: cpIdx)
                let promptB = buildDetectionPrompt(reading: cpReading, window: window, context: context)
                promptTokensB.append(Self.estimateTokens(promptB))

                let t0B = Date()
                let rawB = (try? await gemma.generate(prompt: promptB)) ?? fallbackDetection
                inferenceMsB.append(Date().timeIntervalSince(t0B) * 1000)

                let decision = parseAnomalyDecision(rawB)
                augmentedDecisions.append(decision)
                storage.storeCheckpointDecision(
                    index:           cpIdx,
                    minute:          cpReading.minute,
                    anomalyDetected: decision.detected,
                    severity:        decision.severity,
                    trend:           decision.trend
                )

                // Task 2 — risk prediction
                let nextHasFault = cpIdx + 1 < numCPs ? dataset.windowHasAnomaly(cpIndex: cpIdx + 1) : false
                let predCtxMain  = storage.buildContextBlock(currentMinute: cpReading.minute)
                let predCtxPrec  = storage.buildPredictionContext(currentMinute: cpReading.minute)
                let predCtx      = [predCtxMain, predCtxPrec].filter { !$0.isEmpty }.joined(separator: "\n\n")
                let predProm = buildPredictionPrompt(reading: cpReading, context: predCtx)
                promptTokensPred.append(Self.estimateTokens(predProm))

                let t0P = Date()
                let rawP = (try? await gemma.generate(prompt: predProm)) ?? fallbackPrediction
                inferenceMsPred.append(Date().timeIntervalSince(t0P) * 1000)
                predictions.append(parsePrediction(rawP, nextWindowHasFault: nextHasFault))

                progress += 1
            }

            // ── Task 3 — Cumulative maintenance report ────────────────────
            appendLog("\n── Task 3: Maintenance report ──")
            let gt = GroundTruth(
                totalAnomalies: dataset.stats.anomaly_count,
                maxTemp:        dataset.stats.max_temp,
                minTemp:        dataset.stats.min_temp,
                anomalyMinutes: dataset.stats.anomaly_minutes
            )

            let reportPromptA = buildReportPrompt(context: nil)
            logBlock(title: "REPORT A prompt (stateless)", body: reportPromptA)
            let reportRawA = (try? await gemma.generate(prompt: reportPromptA)) ?? ""
            logBlock(title: "REPORT A raw", body: reportRawA)

            let synthCtx     = storage.buildSynthesisContext()
            let reportPromptB = buildReportPrompt(context: synthCtx)
            logBlock(title: "REPORT B context", body: synthCtx)
            logBlock(title: "REPORT B prompt (augmented)", body: reportPromptB)
            let reportRawB = (try? await gemma.generate(prompt: reportPromptB)) ?? ""
            logBlock(title: "REPORT B raw", body: reportRawB)

            progress += 1

            // ── Assemble & score ──────────────────────────────────────────
            let checkpoints: [CheckpointResult] = (0..<numCPs).map { i in
                CheckpointResult(
                    cpIndex:          i,
                    minute:           dataset.readings[dataset.checkpointIndices[i]].minute,
                    windowHasAnomaly: dataset.windowHasAnomaly(cpIndex: i),
                    stateless:        statelessDecisions[i],
                    augmented:        augmentedDecisions[i],
                    prediction:       predictions[i],
                    backendLatencyUs: backendLatencies[i],
                    inferenceMsA:     inferenceMsA[i],
                    inferenceMsB:     inferenceMsB[i],
                    promptTokensA:    promptTokensA[i],
                    promptTokensB:    promptTokensB[i],
                    promptTokensPred: promptTokensPred[i],
                    contextBlock:     i < contextBlocks.count ? contextBlocks[i] : ""
                )
            }

            let reportStateless = scoreReport(reportRawA, groundTruth: gt)
            let reportAugmented = scoreReport(reportRawB, groundTruth: gt)

            // Legacy synthesis block for cross-run JSON comparability
            let synthesis = SynthesisResult(
                statelessRaw:   reportRawA,
                augmentedRaw:   reportRawB,
                statelessScore: SynthesisScore(
                    anomalyCountCorrect: reportStateless.faultCountCorrect,
                    maxTempCorrect:      reportStateless.maxTempCorrect,
                    dropoutMentioned:    reportStateless.minTempCorrect,
                    anomalyCountExtracted: extractJsonInt(reportRawA, key: "total_faults"),
                    maxTempExtracted:      extractJsonDouble(reportRawA, key: "max_temp")
                ),
                augmentedScore: SynthesisScore(
                    anomalyCountCorrect: reportAugmented.faultCountCorrect,
                    maxTempCorrect:      reportAugmented.maxTempCorrect,
                    dropoutMentioned:    reportAugmented.minTempCorrect,
                    anomalyCountExtracted: extractJsonInt(reportRawB, key: "total_faults"),
                    maxTempExtracted:      extractJsonDouble(reportRawB, key: "max_temp")
                )
            )

            let batteryAfter = SystemSnapshot.batterySnapshot()
            let expResults = ExperimentResults(
                type:            "full_experiment_v2",
                device:          UIDevice.current.model + " (" + UIDevice.current.systemVersion + ")",
                model:           (modelPath as NSString).lastPathComponent,
                backend:         backendName,
                platform:        "iOS",
                timestamp:       ISO8601DateFormatter().string(from: Date()),
                deviceInfo:      SystemSnapshot.deviceInfo(),
                batteryBefore:   batteryBefore,
                batteryAfter:    batteryAfter,
                checkpoints:     checkpoints,
                reportStateless: reportStateless,
                reportAugmented: reportAugmented,
                synthesis:       synthesis,
                groundTruth:     gt
            )

            results = expResults
            printSummary(expResults)
            ResultsExporter.export(expResults)

        } catch {
            appendLog("ERROR: \(error.localizedDescription)")
        }

        isRunning = false
    }

    // MARK: - Server setup

    private func ensureServer(for backendName: String) {
        let server = DazzleServer.shared
        // Server is always started in DazzleExperimentApp.init() with [.lua, .vectorSearch].
        // Never stop it here — stopping while backgrounded fails silently on iOS.
        if !server.isRunning {
            _ = try? server.start(config: DazzleConfig(
                port:        6380,
                maxMemory:   "32mb",
                persistence: .none,
                wipeOnStart: [.aof, .rdb],
                modules:     [.lua, .vectorSearch]
            ))
            _ = server.waitForReady(timeout: 5.0)
        }
    }

    // MARK: - Backend factory

    private func createBackend(name: String) -> StorageBackend {
        switch name.lowercased() {
        case "dazzle-vector":   return DazzleVectorIoTValkey9Manager()
        case "dazzle-lua":      return DazzleLuaContextManager()
        case "dazzle-pipeline": return DazzlePipelineContextManager()
        case "dazzle-hfe":      return DazzleHFEContextManager()
        case "dazzle-hll":      return DazzleHLLContextManager()
        case "dazzle":          return DazzleContextManager()
        default:                return DazzlePrecomputeIoTManager()
        }
    }

    // MARK: - Prompt builders

    private func buildDetectionPrompt(reading: DatasetReading,
                                      window: [DatasetReading],
                                      context: String?) -> String {
        let wMax     = window.map { $0.tempC }.max() ?? reading.tempC
        let wMin     = window.map { $0.tempC }.min() ?? reading.tempC
        let hotFault = wMax > Self.FAULT_HIGH
        let coldFault = wMin < Self.FAULT_LOW
        let faultLine: String
        if hotFault && coldFault {
            faultLine = "⚠ FAULT: max \(f1(wMax))°C (>\(Self.FAULT_HIGH)) AND min \(f1(wMin))°C (<\(Self.FAULT_LOW))"
        } else if hotFault {
            faultLine = "⚠ FAULT: window max \(f1(wMax))°C exceeds hot threshold (\(Self.FAULT_HIGH)°C)"
        } else if coldFault {
            faultLine = "⚠ FAULT: window min \(f1(wMin))°C below cold threshold (\(Self.FAULT_LOW)°C)"
        } else {
            faultLine = "OK: window \(f1(wMin))–\(f1(wMax))°C within normal limits"
        }
        let directive = context == nil ? "No memory — classify from readings only."
                                       : "Memory context above — use it to calibrate severity."
        let question = """
            t=\(reading.minute)min | current: \(f1(reading.tempC))°C | humidity:\(f0(reading.humidity))%
            \(faultLine)
            \(directive)
            Classify: {"anomaly":"yes" or "no","severity":"none" or "low" or "high","trend":"stable" or "increasing" or "decreasing"}
            """
        return GemmaEngine.buildPrompt(context: context, question: question)
    }

    private func buildPredictionPrompt(reading: DatasetReading, context: String?) -> String {
        let directive = context == nil ? "No memory available."
                                       : "Use memory context above to recognize recurring fault patterns."
        let question = """
            t=\(reading.minute)min | current: \(f1(reading.tempC))°C
            \(directive)
            Predict the risk of a fault event in the NEXT 20 minutes for this sensor.
            Reply: {"risk_pct":<0-100>,"risk_level":"low" or "medium" or "high","reasoning":"<one sentence>"}
            """
        return GemmaEngine.buildPrompt(context: context, question: question)
    }

    private func buildReportPrompt(context: String?) -> String {
        let directive = context == nil ? "No session data available — answer from inference only."
                                       : "Full session data is provided above."
        let question = """
            You have completed a \(context == nil ? "monitoring" : "400-minute") session.
            \(directive)
            Provide a maintenance report:
            1. Total fault events detected
            2. Maximum temperature recorded
            3. Minimum temperature recorded (cold-fault / dropout?)
            4. Fault pattern types observed (spike / drift / dropout / oscillation / precursor)
            5. Overall sensor health: healthy / degraded / critical
            Reply: {"total_faults":<int>,"max_temp":<float>,"min_temp":<float>,"patterns":"<comma-separated>","health":"healthy" or "degraded" or "critical","summary":"<one sentence>"}
            """
        return GemmaEngine.buildPrompt(context: context, question: question)
    }

    // MARK: - Parsing

    private func parseAnomalyDecision(_ raw: String) -> AnomalyDecision {
        let anomaly  = extractJsonString(raw, key: "anomaly")  ?? "no"
        let severity = extractJsonString(raw, key: "severity") ?? "none"
        let trend    = extractJsonString(raw, key: "trend")    ?? "stable"
        return AnomalyDecision(
            detected: anomaly.lowercased() == "yes",
            severity: severity.lowercased(),
            trend:    trend.lowercased(),
            rawJson:  raw
        )
    }

    private func parsePrediction(_ raw: String, nextWindowHasFault: Bool) -> RiskPrediction {
        let riskPct   = extractJsonInt(raw, key: "risk_pct") ?? 50
        let riskLevel = extractJsonString(raw, key: "risk_level") ?? "medium"
        let predicted = riskPct >= 50
        return RiskPrediction(
            riskPct:            min(100, max(0, riskPct)),
            riskLevel:          riskLevel.lowercased(),
            rawJson:            raw,
            nextWindowHasFault: nextWindowHasFault,
            predictionCorrect:  predicted == nextWindowHasFault
        )
    }

    // MARK: - Scoring

    private func scoreReport(_ raw: String, groundTruth gt: GroundTruth) -> ReportScore {
        let count = extractJsonInt(raw,    key: "total_faults")
        let maxT  = extractJsonDouble(raw, key: "max_temp")
        let minT  = extractJsonDouble(raw, key: "min_temp")
        let lower = raw.lowercased()

        let countOk = count.map { abs($0 - gt.totalAnomalies) <= 3 } ?? false
        let maxOk   = maxT.map  { abs($0 - gt.maxTemp) <= 2.0 } ?? false
        let minOk   = minT.map  { $0 < 5.0 } ?? false

        let patternKeywords = ["spike", "drift", "dropout", "oscillation", "precursor"]
        let patternsFound   = patternKeywords.filter { lower.contains($0) }.count

        return ReportScore(
            faultCountCorrect:  countOk,
            maxTempCorrect:     maxOk,
            minTempCorrect:     minOk,
            patternsIdentified: patternsFound,
            consistencyScore:   [countOk, maxOk, minOk].filter { $0 }.count,
            raw:                raw
        )
    }

    // MARK: - Summary

    private func printSummary(_ r: ExperimentResults) {
        let tp = r.checkpoints.filter { $0.windowHasAnomaly }
        let tn = r.checkpoints.filter { !$0.windowHasAnomaly }

        let recallA = Double(tp.filter { $0.stateless.detected }.count) / Double(max(1, tp.count))
        let recallB = Double(tp.filter { $0.augmented.detected }.count) / Double(max(1, tp.count))
        let fprA    = Double(tn.filter { $0.stateless.detected }.count) / Double(max(1, tn.count))
        let fprB    = Double(tn.filter { $0.augmented.detected }.count) / Double(max(1, tn.count))

        let preds    = r.checkpoints.compactMap { $0.prediction }
        let predAcc  = preds.isEmpty ? 0.0 : Double(preds.filter { $0.predictionCorrect }.count) / Double(preds.count)
        let predRec  = Double(preds.filter { $0.nextWindowHasFault && $0.predictionCorrect }.count) /
                       Double(max(1, preds.filter { $0.nextWindowHasFault }.count))

        let repA = r.reportStateless
        let repB = r.reportAugmented
        let avgLat  = r.checkpoints.map { $0.backendLatencyUs }.reduce(0, +) / Double(r.checkpoints.count)
        let avgTokA = Double(r.checkpoints.map { $0.promptTokensA }.reduce(0, +)) / Double(r.checkpoints.count)
        let avgTokB = Double(r.checkpoints.map { $0.promptTokensB }.reduce(0, +)) / Double(r.checkpoints.count)

        appendLog("""

            ══════════════════════════════════════════════════════
              EXPERIMENT v2 COMPLETE — \(r.device)
            ══════════════════════════════════════════════════════
            Model   : \(r.model)   Backend: \(r.backend)
            Dataset : 400 readings, \(r.checkpoints.count) checkpoints, \(tp.count) fault windows

            Task 1 — Fault Detection:
              Recall    A(stateless)=\(pct(recallA))  B(augmented)=\(pct(recallB))  Δ=\(pct(recallB-recallA))
              FPR       A=\(pct(fprA))  B=\(pct(fprB))

            Task 2 — Risk Prediction (augmented only):
              Accuracy  \(pct(predAcc))  |  Fault-recall \(pct(predRec))

            Task 3 — Maintenance Report:
              Stateless : count_ok=\(repA.faultCountCorrect)  max_ok=\(repA.maxTempCorrect)  min_ok=\(repA.minTempCorrect)  patterns=\(repA.patternsIdentified)/5  score=\(repA.consistencyScore)/3
              Augmented : count_ok=\(repB.faultCountCorrect)  max_ok=\(repB.maxTempCorrect)  min_ok=\(repB.minTempCorrect)  patterns=\(repB.patternsIdentified)/5  score=\(repB.consistencyScore)/3

            Avg tokens: A=\(String(format: "%.0f", avgTokA))  B=\(String(format: "%.0f", avgTokB))
            Retrieval latency: \(String(format: "%.1f", avgLat)) µs avg
            """)
    }

    // MARK: - Helpers

    private var fallbackDetection: String {
        "{\"anomaly\":\"no\",\"severity\":\"none\",\"trend\":\"stable\"}"
    }
    private var fallbackPrediction: String {
        "{\"risk_pct\":50,\"risk_level\":\"medium\",\"reasoning\":\"no data\"}"
    }

    private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func pct(_ v: Double) -> String { String(format: "%+.0f%%", v * 100) }

    static func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }

    private func appendLog(_ text: String) {
        log += text + "\n"
        print(text)
    }

    private func logBlock(title: String, body: String) {
        let banner = "────── \(title) ──────"
        appendLog("\n\(banner)")
        appendLog(body)
        appendLog(String(repeating: "─", count: banner.count))
    }

    // MARK: - JSON helpers

    private func extractJsonString(_ s: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[range])
    }

    private func extractJsonInt(_ s: String, key: String) -> Int? {
        let pattern = "\"\(key)\"\\s*:\\s*([0-9]+)"
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[range])
    }

    private func extractJsonDouble(_ s: String, key: String) -> Double? {
        let pattern = "\"\(key)\"\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)"
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range(at: 1), in: s) else { return nil }
        return Double(s[range])
    }
}
