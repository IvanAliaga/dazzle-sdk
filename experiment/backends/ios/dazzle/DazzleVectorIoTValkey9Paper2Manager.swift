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

/// Plan 18 — Dazzle-Vector: the full-stack Valkey 9 edge-AI backend.
///
/// Integrates every Valkey 9 primitive to maximise all three experiment tasks:
///
///   Task 1 — Detection:
///     • Precompute ctx_block  → session stats, OLS trend, active fault window (1 getDirect)
///     • Temperature velocity  → rate-of-change signal stored via pipeline HSET
///     • HNSW vIdx KNN-5       → episodic memory: similar past readings with ground-truth labels
///     • HFE agent:memory      → non-expired checkpoint decisions for in-window decision history
///
///   Task 2 — Prediction:
///     • HNSW precursorIdx KNN-3 → confirmed pre-fault signatures, labelled at fault-confirm time
///
///   Task 3 — Report:
///     • HyperLogLog ×2        → compact anomaly cardinality + distinct pattern diversity
///     • HFE agent:memory      → synthesis sees only recent decisions (decaying memory)
///     • Precompute synthesis   → full anomaly minute list + session stats
///
/// ## HNSW encoding  (dim = 4, deterministic)
///   [0] tempNorm  = clamp((tempC − 20) / 20, −1, 1)
///   [1] minSin    = sin(2π × minute / 200)
///   [2] minCos    = cos(2π × minute / 200)
///   [3] anomFlag  = 1.0 if tempC > 28 or < 5 else 0.0
///
/// Requires DazzleModule.vectorSearch + .lua in DazzleConfig.modules at server start.
final class DazzleVectorIoTValkey9Paper2Manager: StorageBackend {

    let backendName = "Dazzle-Vector"

    private let server:     DazzleServer
    private let stats:      HashKey
    private let anomalies:  SortedSetKey
    private let precompute: DazzlePrecomputeIoTManager

    // ── Vector indexes ────────────────────────────────────────────────────
    private let vIdx:        VectorIndex   // episodic memory (all readings)
    private let precursorIdx: VectorIndex  // confirmed pre-fault signatures

    // ── HyperLogLog — anomaly cardinality (Task 3) ───────────────────────
    private let anomalyHLL:     HyperLogLogKey
    private let anomalyTypeHLL: HyperLogLogKey

    // ── Exact type counts — hash field→count for named pattern listing ────
    private let anomalyTypeCounts: HashKey

    // ── HFE hash — recency-weighted agent decisions (Task 1 + 3) ─────────
    private let agentMemory: HashKey

    // ── Constants ─────────────────────────────────────────────────────────
    private static let DIM                      = 4
    private static let KNN_K                    = 5
    private static let PRECURSOR_K              = 3
    private static let PRECURSOR_LOOKBACK_START = 40
    private static let PRECURSOR_LOOKBACK_END   = 20
    private static let MAX_PRECURSOR_SOURCES    = 2  // keep last N confirmed faults
    private static let MIN_KNN_SCORE: Float     = 0.35  // cosine distance upper bound; drops weak matches
    // HFE TTL: CP0 = 30 s → CP9 = 120 s. Decisions decay so synthesis
    // focuses on recent confirmed patterns rather than full history.
    private static let HFE_TTL_BASE: Int64  = 30
    private static let HFE_TTL_STEP: Int64  = 10

    init() {
        self.server    = DazzleServer.shared
        let dazzle     = server.client()
        self.stats     = dazzle.hash("sensor:stats")
        self.anomalies = dazzle.sortedSet("sensor:anomalies")
        self.precompute = DazzlePrecomputeIoTManager()

        self.vIdx = server.vectorIndex(
            name:        "sensor:vindex",
            hashPrefix:  "svec:",
            vectorField: "emb",
            dim:         Self.DIM,
            algorithm:   .hnsw,
            metric:      .cosine
        )
        self.precursorIdx = server.vectorIndex(
            name:        "sensor:pvindex",
            hashPrefix:  "pvec:",
            vectorField: "emb",
            dim:         Self.DIM,
            algorithm:   .hnsw,
            metric:      .cosine
        )
        self.anomalyHLL        = dazzle.hyperLogLog("sensor:anomaly_hll")
        self.anomalyTypeHLL    = dazzle.hyperLogLog("sensor:anomaly_type_hll")
        self.anomalyTypeCounts = dazzle.hash("sensor:anomaly_type_counts")
        self.agentMemory       = dazzle.hash("agent:memory")

        vIdx.create()
        precursorIdx.create()
    }

    // MARK: - Lifecycle

    func flush() {
        precompute.flush()
        _ = vIdx.drop()
        _ = precursorIdx.drop()
        let luaSvec = "local k=redis.call('KEYS','svec:*'); if #k>0 then redis.call('DEL',unpack(k)) end; return #k"
        let luaPvec = "local k=redis.call('KEYS','pvec:*'); if #k>0 then redis.call('DEL',unpack(k)) end; return #k"
        _ = server.directArgs(["EVAL", luaSvec, "0"])
        _ = server.directArgs(["EVAL", luaPvec, "0"])
        _ = vIdx.create()
        _ = precursorIdx.create()
        _ = try? anomalyHLL.deleteKey()
        _ = try? anomalyTypeHLL.deleteKey()
        _ = try? anomalyTypeCounts.deleteKey()
        _ = try? agentMemory.deleteKey()
    }

    // MARK: - Ingest

    func ingest(_ reading: SensorReading) {
        // Read previous temp BEFORE precompute updates it so we can compute velocity.
        let prevTemp = (try? stats.get("latest_temp")).flatMap { $0 }.flatMap { Double($0) }

        // Precompute ingest: 1 EVALSHA → stream + running aggregates + OLS trend
        // + active fault window + pre-rendered ctx_block. Zero Kotlin/Swift mutex.
        precompute.ingest(reading)

        // Encode vector and add to main episodic index with float components
        // stored as metadata for retroactive precursor lookup.
        let vec = encodeReading(tempC: reading.tempC,
                                minute: Double(reading.minute),
                                anomalous: reading.anomalous)
        vIdx.add(
            id:     "svec:\(reading.minute)",
            vector: vec,
            metadata: [
                "minute":    String(reading.minute),
                "temp":      String(format: "%.1f", reading.tempC),
                "anomalous": reading.anomalous ? "1" : "0",
                "f0": String(format: "%.6f", vec[0]),
                "f1": String(format: "%.6f", vec[1]),
                "f2": String(format: "%.6f", vec[2]),
                "f3": String(format: "%.6f", vec[3]),
            ]
        )

        // Pipeline: velocity + HLL writes — one round-trip for all derived fields.
        let velocity = prevTemp.map { reading.tempC - $0 } ?? 0.0
        var cmds: [[String]] = [
            ["HSET", "sensor:stats", "temp_velocity", String(format: "%.2f", velocity)]
        ]
        if reading.anomalous {
            let type = anomalyType(tempC: reading.tempC)
            cmds.append(["PFADD",   "sensor:anomaly_hll",        String(reading.minute)])
            cmds.append(["PFADD",   "sensor:anomaly_type_hll",   type])
            cmds.append(["HINCRBY", "sensor:anomaly_type_counts", type, "1"])
        }
        _ = server.directPipelineArgs(cmds)
    }

    // MARK: - Detection context (Task 1)

    func buildContextBlock(currentMinute: Int, windowMinutes: Int = 20) -> String {
        // 1. Precompute operational state (1 getDirect — snapshot-cached)
        let kvCtx  = precompute.buildContextBlock(currentMinute: currentMinute,
                                                   windowMinutes: windowMinutes)
        // 2. Velocity: rate-of-change pre-fault signal
        let velCtx = buildVelocityContext()
        // 3. HNSW episodic memory + HFE recent decisions
        let knnCtx = buildKnnContext(currentMinute: currentMinute)
        return [kvCtx, velCtx, knnCtx].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func buildVelocityContext() -> String {
        guard let raw = (try? stats.get("temp_velocity")).flatMap({ $0 }),
              let vel = Double(raw), abs(vel) > 0.05 else { return "" }
        let dir = vel > 0 ? "rising" : "falling"
        let urgency: String
        switch vel {
        case let v where v > 2.0:  urgency = " — RAPID RISE, approaching fault threshold"
        case let v where v < -2.0: urgency = " — RAPID DROP, approaching dropout threshold"
        case let v where v > 1.0:  urgency = " — fast rise"
        case let v where v < -1.0: urgency = " — fast fall"
        default:                   urgency = ""
        }
        return "[Temperature Velocity]\n\(String(format: "%.2f", vel))°C/reading \(dir)\(urgency)"
    }

    private func buildKnnContext(currentMinute: Int) -> String {
        let latestTemp = (try? stats.get("latest_temp")).flatMap { $0 }.flatMap { Double($0) } ?? 20.0
        let isAnom     = latestTemp > 28.0 || latestTemp < 5.0

        let query      = encodeReading(tempC: latestTemp, minute: Double(currentMinute), anomalous: isAnom)
        let rawResults = vIdx.search(query: query, k: Self.KNN_K,
                                     returnFields: ["minute", "temp", "anomalous"])
        let results    = rawResults.filter { $0.score <= Self.MIN_KNN_SCORE }

        var lines: [String] = []

        if !results.isEmpty {
            let faultMatches  = results.filter { $0.fields["anomalous"] == "1" }
            let normalMatches = results.filter { $0.fields["anomalous"] != "1" }
            let faultPct      = (faultMatches.count * 100) / results.count

            lines.append("[Episodic Memory — HNSW k=\(Self.KNN_K)]")
            lines.append("Pattern signal: \(faultPct)% of the \(Self.KNN_K) most similar past readings were FAULT events (\(100 - faultPct)% normal).")
            if !faultMatches.isEmpty {
                let fm = faultMatches.map { "t=\($0.fields["minute"] ?? "?")min \($0.fields["temp"] ?? "?")°C" }
                                     .joined(separator: " | ")
                lines.append("  Fault matches: \(fm)")
            }
            if !normalMatches.isEmpty {
                let nm = normalMatches.map { "t=\($0.fields["minute"] ?? "?")min \($0.fields["temp"] ?? "?")°C" }
                                      .joined(separator: " | ")
                lines.append("  Normal matches: \(nm)")
            }
        }

        // HFE agent memory — only non-expired checkpoint decisions are visible.
        let memFields = (try? agentMemory.getAll()) ?? [:]
        if !memFields.isEmpty {
            let sorted = memFields
                .compactMap { k, v -> (Int, String)? in
                    guard let idx = Int(k.replacingOccurrences(of: "cp_", with: "")) else { return nil }
                    return (idx, v)
                }
                .sorted { $0.0 < $1.0 }
            if !sorted.isEmpty {
                lines.append("[Recent Agent Decisions — HFE decaying memory]")
                for (idx, decision) in sorted {
                    lines.append("  CP\(idx + 1): \(decision)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Prediction context (Task 2) — precursor index signal

    func buildPredictionContext(currentMinute: Int) -> String {
        let latestTemp = (try? stats.get("latest_temp")).flatMap { $0 }.flatMap { Double($0) } ?? 20.0
        let isAnom     = latestTemp > 28.0 || latestTemp < 5.0

        let query      = encodeReading(tempC: latestTemp, minute: Double(currentMinute), anomalous: isAnom)
        let rawResults = precursorIdx.search(query: query, k: Self.PRECURSOR_K,
                                             returnFields: ["pre_minute", "pre_temp", "fault_minute"])
        let results    = rawResults.filter { $0.score <= Self.MIN_KNN_SCORE }
        guard !results.isEmpty else { return "" }

        let matchPct    = (results.count * 100) / Self.PRECURSOR_K
        let faultSources = results.compactMap { $0.fields["fault_minute"] }
                                  .map { "fault@t=\($0)min" }
                                  .joined(separator: " | ")

        var lines: [String] = ["[Precursor Memory — confirmed pre-fault signatures, HNSW k=\(Self.PRECURSOR_K)]"]
        lines.append("Match rate: \(matchPct)% of neighbors are confirmed pre-fault readings.")
        switch matchPct {
        case 67...: lines.append("HIGH RISK SIGNAL: current profile closely matches pre-fault conditions.")
        case 33...: lines.append("MODERATE RISK SIGNAL: some similarity to pre-fault conditions.")
        default:    lines.append("LOW RISK SIGNAL: current profile differs from known pre-fault patterns.")
        }
        if !faultSources.isEmpty { lines.append("  Source faults: \(faultSources)") }
        let neighbors = results.map { "t=\($0.fields["pre_minute"] ?? "?")min \($0.fields["pre_temp"] ?? "?")°C" }
                               .joined(separator: " | ")
        lines.append("  Matching pre-fault readings: \(neighbors)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Synthesis context (Task 3)

    func buildSynthesisContext() -> String {
        var parts: [String] = []

        // Precompute synthesis: full session stats + anomaly minutes + decisions list
        let base = precompute.buildSynthesisContext()
        if !base.isEmpty { parts.append(base) }

        // HFE decisions (may differ from full list if early ones expired)
        let memFields = (try? agentMemory.getAll()) ?? [:]
        if !memFields.isEmpty {
            let sorted = memFields
                .compactMap { k, v -> (Int, String)? in
                    guard let idx = Int(k.replacingOccurrences(of: "cp_", with: "")) else { return nil }
                    return (idx, v)
                }
                .sorted { $0.0 < $1.0 }
            var memLines = ["[Agent Memory — HFE decaying view]"]
            for (idx, decision) in sorted {
                memLines.append("  CP\(idx + 1): \(decision)")
            }
            parts.append(memLines.joined(separator: "\n"))
        }

        // HLL cardinality + exact type listing from counts hash
        let uniqueAnomalies = (try? anomalyHLL.count()) ?? 0
        if uniqueAnomalies > 0 {
            let typeCounts = (try? anomalyTypeCounts.getAll()) ?? [:]
            let typeList = typeCounts
                .sorted { ($0.value as? String).flatMap(Int.init) ?? 0 >
                          ($1.value as? String).flatMap(Int.init) ?? 0 }
                .map { "\($0.key)(\($0.value)×)" }
                .joined(separator: ", ")
            parts.append("[Anomaly Profile]\n" +
                "Total fault readings (HLL): ~\(uniqueAnomalies) | " +
                "Types: \(typeList)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Checkpoint decision storage

    func storeCheckpointDecision(index: Int, minute: Int,
                                  anomalyDetected: Bool, severity: String, trend: String) {
        precompute.storeCheckpointDecision(index: index, minute: minute,
                                            anomalyDetected: anomalyDetected,
                                            severity: severity, trend: trend)

        // HFE: store in agent:memory with per-field TTL.
        // Early CPs get shorter TTL so synthesis focuses on recent patterns.
        // CP0 → 30 s, CP1 → 40 s, …, CP9 → 120 s.
        let decision = "anomaly=\(anomalyDetected ? "yes" : "no") severity=\(severity) trend=\(trend) @min=\(minute)"
        _ = try? agentMemory.set("cp_\(index)", decision)
        let ttl = Self.HFE_TTL_BASE + Int64(index) * Self.HFE_TTL_STEP
        _ = try? agentMemory.expireField("cp_\(index)", seconds: ttl)

        // Precursor indexing: when a fault is confirmed, retroactively add
        // readings from [minute−40, minute−20] to precursorIdx so future
        // prediction queries can recognise confirmed pre-fault profiles.
        guard anomalyDetected else { return }
        let dazzle = server.client()

        // Rolling precursor window — evict oldest fault before adding new one.
        // Without this cap the index accumulates across all faults and KNN-3
        // starts matching normal windows to stale pre-fault patterns (false positives).
        let historyRaw = (try? stats.get("precursor_fault_history")).flatMap { $0 } ?? ""
        var history = historyRaw.split(separator: ",").compactMap { Int($0) }
        while history.count >= Self.MAX_PRECURSOR_SOURCES {
            let evict  = history.removeFirst()
            let eStart = max(0, evict - Self.PRECURSOR_LOOKBACK_START)
            let eEnd   = max(0, evict - Self.PRECURSOR_LOOKBACK_END)
            if eStart <= eEnd {
                for m in eStart...eEnd { _ = server.directArgs(["DEL", "pvec:\(evict)_\(m)"]) }
            }
        }
        history.append(minute)
        _ = try? stats.set("precursor_fault_history", history.map(String.init).joined(separator: ","))

        let start  = max(0, minute - Self.PRECURSOR_LOOKBACK_START)
        let end    = max(0, minute - Self.PRECURSOR_LOOKBACK_END)
        guard start <= end else { return }
        for m in start...end {
            let hash = dazzle.hash("svec:\(m)")
            guard let components = try? hash.mGet("f0", "f1", "f2", "f3"),
                  components.count == 4,
                  let f0 = components[0].flatMap({ Float($0) }),
                  let f1 = components[1].flatMap({ Float($0) }),
                  let f2 = components[2].flatMap({ Float($0) }),
                  let f3 = components[3].flatMap({ Float($0) }) else { continue }
            let tempStr = (try? hash.mGet("temp"))?.first?.flatMap { $0 } ?? "?"
            precursorIdx.add(
                id:     "pvec:\(minute)_\(m)",
                vector: [f0, f1, f2, f3],
                metadata: [
                    "pre_minute":  String(m),
                    "pre_temp":    tempStr,
                    "fault_minute": String(minute),
                ]
            )
        }
    }

    func measureRetrievalLatency(currentMinute: Int) -> Double {
        let start = DispatchTime.now()
        _ = buildContextBlock(currentMinute: currentMinute)
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000.0
    }

    // MARK: - Helpers

    private func encodeReading(tempC: Double, minute: Double, anomalous: Bool) -> [Float] {
        let tempNorm = Float(max(-1.0, min(1.0, (tempC - 20.0) / 20.0)))
        let angle    = 2.0 * Double.pi * minute / 200.0
        let anomFlag: Float = (anomalous || tempC > 28.0 || tempC < 5.0) ? 1.0 : 0.0
        return [tempNorm, Float(sin(angle)), Float(cos(angle)), anomFlag]
    }

    private func anomalyType(tempC: Double) -> String {
        switch tempC {
        case let t where t > 32.0: return "spike_high"
        case let t where t > 28.0: return "spike_moderate"
        case let t where t < 2.0:  return "dropout_severe"
        case let t where t < 5.0:  return "dropout"
        default:                   return "oscillation"
        }
    }
}
