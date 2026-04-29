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
// ResultsExporter
//
// Serialises ExperimentResults to JSON and writes it to the app's Documents
// folder so it can be retrieved via Xcode → Devices & Simulators → Download
// Container, or airdrop.
//
// The schema mirrors the Android exporter (ExperimentPipelineIoT.kt:serialise),
// so a single downstream analysis script consumes both platforms' files.
// ─────────────────────────────────────────────────────────────────────────────

struct ResultsExporter {

    static func export(_ results: ExperimentResults) {
        let dict = serialise(results)
        guard JSONSerialization.isValidJSONObject(dict) else {
            print("[ResultsExporter] ERROR: result dict not JSON-serializable")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                      options: [.prettyPrinted, .sortedKeys]) else {
            print("[ResultsExporter] JSON serialisation failed")
            return
        }

        let docsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let deviceSlug = results.device
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let url = docsDir.appendingPathComponent("experiment_ios_\(deviceSlug)_\(ts).json")

        do {
            try data.write(to: url)
            print("[ResultsExporter] Saved → \(url.path)")
        } catch {
            print("[ResultsExporter] Write error: \(error)")
        }
    }

    // MARK: - Serialisation

    private static func serialise(_ r: ExperimentResults) -> [String: Any] {
        var d: [String: Any] = [:]
        d["type"]        = r.type
        d["device"]      = r.device
        d["model"]       = r.model
        d["backend"]     = r.backend
        d["backend_key"] = r.backend.lowercased()
        d["platform"]    = r.platform
        d["timestamp"]   = r.timestamp
        d["device_info"] = r.deviceInfo
        if let b = r.batteryBefore { d["battery_before"] = b }
        if let b = r.batteryAfter  { d["battery_after"]  = b }

        d["ground_truth"] = [
            "total_anomalies":  r.groundTruth.totalAnomalies,
            "max_temp":         r.groundTruth.maxTemp,
            "min_temp":         r.groundTruth.minTemp,
            "anomaly_minutes":  r.groundTruth.anomalyMinutes
        ]

        d["checkpoints"] = r.checkpoints.map { cp -> [String: Any] in
            var cpDict: [String: Any] = [
                "cp_index":           cp.cpIndex,
                "minute":             cp.minute,
                "window_has_anomaly": cp.windowHasAnomaly,
                "stateless": [
                    "detected": cp.stateless.detected,
                    "severity": cp.stateless.severity,
                    "trend":    cp.stateless.trend,
                    "raw_json": cp.stateless.rawJson
                ],
                "augmented": [
                    "detected": cp.augmented.detected,
                    "severity": cp.augmented.severity,
                    "trend":    cp.augmented.trend,
                    "raw_json": cp.augmented.rawJson
                ],
                "backend_latency_us":  cp.backendLatencyUs,
                "inference_ms_a":      cp.inferenceMsA,
                "inference_ms_b":      cp.inferenceMsB,
                "prompt_tokens_a":     cp.promptTokensA,
                "prompt_tokens_b":     cp.promptTokensB,
                "prompt_tokens_pred":  cp.promptTokensPred,
                "context_block":       cp.contextBlock
            ]
            if let pred = cp.prediction {
                cpDict["prediction"] = [
                    "risk_pct":              pred.riskPct,
                    "risk_level":            pred.riskLevel,
                    "next_window_has_fault": pred.nextWindowHasFault,
                    "prediction_correct":    pred.predictionCorrect,
                    "raw_json":              pred.rawJson
                ]
            }
            return cpDict
        }

        d["synthesis"] = [
            "stateless_raw":   r.synthesis.statelessRaw,
            "augmented_raw":   r.synthesis.augmentedRaw,
            "stateless_score": serialiseScore(r.synthesis.statelessScore),
            "augmented_score": serialiseScore(r.synthesis.augmentedScore)
        ]

        d["report"] = [
            "stateless": serialiseReportScore(r.reportStateless),
            "augmented": serialiseReportScore(r.reportAugmented)
        ]

        let tpCPs = r.checkpoints.filter { $0.windowHasAnomaly }
        let tnCPs = r.checkpoints.filter { !$0.windowHasAnomaly }
        let recallA = Double(tpCPs.filter { $0.stateless.detected }.count) / Double(max(1, tpCPs.count))
        let recallB = Double(tpCPs.filter { $0.augmented.detected }.count) / Double(max(1, tpCPs.count))
        let fprA    = Double(tnCPs.filter { $0.stateless.detected }.count) / Double(max(1, tnCPs.count))
        let fprB    = Double(tnCPs.filter { $0.augmented.detected }.count) / Double(max(1, tnCPs.count))
        let avgLat  = r.checkpoints.map { $0.backendLatencyUs }.reduce(0, +) / Double(r.checkpoints.count)

        let avgTokA    = Double(r.checkpoints.map { $0.promptTokensA }.reduce(0, +)) / Double(r.checkpoints.count)
        let avgTokB    = Double(r.checkpoints.map { $0.promptTokensB }.reduce(0, +)) / Double(r.checkpoints.count)
        let avgTokPred = Double(r.checkpoints.map { $0.promptTokensPred }.reduce(0, +)) / Double(r.checkpoints.count)
        let avgInfA    = r.checkpoints.map { $0.inferenceMsA }.reduce(0, +) / Double(r.checkpoints.count)
        let avgInfB    = r.checkpoints.map { $0.inferenceMsB }.reduce(0, +) / Double(r.checkpoints.count)

        // Task 2 — prediction metrics
        let preds       = r.checkpoints.compactMap { $0.prediction }
        let predAcc     = preds.isEmpty ? 0.0
                        : Double(preds.filter { $0.predictionCorrect }.count) / Double(preds.count)
        let faultPreds  = preds.filter { $0.nextWindowHasFault }
        let predFaultRec = faultPreds.isEmpty ? 0.0
                        : Double(faultPreds.filter { $0.predictionCorrect }.count) / Double(faultPreds.count)
        let avgRiskPct  = preds.isEmpty ? 0.0
                        : Double(preds.map { $0.riskPct }.reduce(0, +)) / Double(preds.count)
        let highRiskOnFault = faultPreds.isEmpty ? 0.0
                        : Double(faultPreds.filter { $0.riskPct >= 50 }.count) / Double(faultPreds.count)

        // Task 3 — report metrics
        let repA = r.reportStateless
        let repB = r.reportAugmented

        d["metrics"] = [
            // Task 1 — detection
            "recall_stateless":               recallA,
            "recall_augmented":               recallB,
            "recall_delta":                   recallB - recallA,
            "fpr_stateless":                  fprA,
            "fpr_augmented":                  fprB,
            "true_positive_cps":              tpCPs.count,
            "true_negative_cps":              tnCPs.count,
            // Task 2 — prediction
            "prediction_accuracy":            predAcc,
            "prediction_fault_recall":        predFaultRec,
            "prediction_avg_risk_pct":        avgRiskPct,
            "prediction_high_risk_on_fault":  highRiskOnFault,
            // Task 3 — report
            "report_score_stateless":         repA.consistencyScore,
            "report_score_augmented":         repB.consistencyScore,
            "report_patterns_stateless":      repA.patternsIdentified,
            "report_patterns_augmented":      repB.patternsIdentified,
            "report_fault_count_ok_stateless": repA.faultCountCorrect,
            "report_fault_count_ok_augmented": repB.faultCountCorrect,
            "report_max_temp_ok_stateless":   repA.maxTempCorrect,
            "report_max_temp_ok_augmented":   repB.maxTempCorrect,
            "report_min_temp_ok_stateless":   repA.minTempCorrect,
            "report_min_temp_ok_augmented":   repB.minTempCorrect,
            // Legacy synthesis (cross-run compat)
            "synthesis_score_stateless":      r.synthesis.statelessScore.total,
            "synthesis_score_augmented":      r.synthesis.augmentedScore.total,
            // Latency / tokens
            "backend_avg_latency_us":         avgLat,
            "avg_prompt_tokens_a":            avgTokA,
            "avg_prompt_tokens_b":            avgTokB,
            "avg_prompt_tokens_pred":         avgTokPred,
            "avg_context_tokens":             avgTokB - avgTokA,
            "avg_inference_ms_a":             avgInfA,
            "avg_inference_ms_b":             avgInfB
        ]

        return d
    }

    private static func serialiseScore(_ s: SynthesisScore) -> [String: Any] {
        var d: [String: Any] = [
            "anomaly_count_correct": s.anomalyCountCorrect,
            "max_temp_correct":      s.maxTempCorrect,
            "dropout_mentioned":     s.dropoutMentioned,
            "total":                 s.total
        ]
        if let v = s.anomalyCountExtracted { d["anomaly_count_extracted"] = v }
        if let v = s.maxTempExtracted      { d["max_temp_extracted"]      = v }
        return d
    }

    private static func serialiseReportScore(_ s: ReportScore) -> [String: Any] {
        [
            "fault_count_correct":  s.faultCountCorrect,
            "max_temp_correct":     s.maxTempCorrect,
            "min_temp_correct":     s.minTempCorrect,
            "patterns_identified":  s.patternsIdentified,
            "consistency_score":    s.consistencyScore,
            "raw":                  s.raw
        ]
    }
}

