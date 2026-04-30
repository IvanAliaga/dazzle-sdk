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

package dev.dazzle.experiment

import dev.dazzle.sdk.Dazzle
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.VectorIndex
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * Plan 18 — Dazzle-Vector: the full-stack Valkey edge-AI backend.
 *
 * Integrates every Valkey 8 primitive to maximise all three experiment tasks:
 *
 *   Task 1 — Detection:
 *     • Precompute ctx_block   → session stats, OLS trend, active fault window (1 getDirect)
 *     • Temperature velocity   → rate-of-change signal, pipeline-written on every ingest
 *     • HNSW vIdx KNN-5        → episodic memory: similar past readings with ground-truth labels
 *     • HFE agent:memory       → non-expired checkpoint decisions for in-window decision history
 *
 *   Task 2 — Prediction:
 *     • HNSW precursorIdx KNN-3 → confirmed pre-fault signatures, labelled at fault-confirm time
 *
 *   Task 3 — Report:
 *     • HyperLogLog ×2         → compact anomaly cardinality + distinct pattern diversity
 *     • HFE agent:memory       → synthesis sees only recent decisions (decaying memory)
 *     • Precompute synthesis    → full anomaly minute list + session stats
 *
 * ## HNSW encoding  (dim = 4, deterministic)
 *   [0] tempNorm  = clamp((tempC − 20) / 20, −1, 1)
 *   [1] minSin    = sin(2π × minute / 200)
 *   [2] minCos    = cos(2π × minute / 200)
 *   [3] anomFlag  = 1.0 if tempC > 28 or < 5 else 0.0
 *
 * Requires DazzleModule.VectorSearch in DazzleConfig.modules at server start.
 */
class DazzleVectorIoTValkey8Manager : StorageBackend {

    override val backendName = "Dazzle-Vector"

    private val dazzle: Dazzle = DazzleServer.client()
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")

    private val precompute = DazzlePrecomputeIoTManager()

    // ── Vector indexes ────────────────────────────────────────────────────
    private val vIdx = dazzle.vectorIndex(
        name        = "sensor:vindex",
        hashPrefix  = "svec:",
        vectorField = "emb",
        dim         = DIM,
        algorithm   = VectorIndex.Algorithm.HNSW,
        metric      = VectorIndex.Metric.COSINE,
    )
    private val precursorIdx = dazzle.vectorIndex(
        name        = "sensor:pvindex",
        hashPrefix  = "pvec:",
        vectorField = "emb",
        dim         = DIM,
        algorithm   = VectorIndex.Algorithm.HNSW,
        metric      = VectorIndex.Metric.COSINE,
    )

    // ── HyperLogLog — anomaly cardinality + type diversity (Task 3) ───────
    private val anomalyHLL     = dazzle.hyperLogLog("sensor:anomaly_hll")
    private val anomalyTypeHLL = dazzle.hyperLogLog("sensor:anomaly_type_hll")

    // ── HFE hash — recency-weighted agent decisions (Task 1 + 3) ─────────
    private val agentMemory = dazzle.hash("agent:memory")

    init {
        vIdx.create()
        precursorIdx.create()
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        precompute.flush()
        vIdx.drop()
        precursorIdx.drop()
        DazzleServer.directCommand(
            "EVAL",
            "local k=redis.call('KEYS','svec:*'); if #k>0 then redis.call('DEL',unpack(k)) end; return #k",
            "0",
        )
        DazzleServer.directCommand(
            "EVAL",
            "local k=redis.call('KEYS','pvec:*'); if #k>0 then redis.call('DEL',unpack(k)) end; return #k",
            "0",
        )
        vIdx.create()
        precursorIdx.create()
        anomalyHLL.deleteKey()
        anomalyTypeHLL.deleteKey()
        agentMemory.delete()
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        // Read previous temp BEFORE precompute updates it for velocity computation.
        val prevTemp = stats.getDirect("latest_temp")?.toDoubleOrNull()

        // Precompute ingest: 1 EVALSHA → stream + running aggregates + OLS trend
        // + active fault window + pre-rendered ctx_block. No JVM monitor.
        precompute.ingest(reading)

        // Encode vector and index with float components stored for retroactive
        // precursor lookup without re-encoding from raw readings.
        val vec = encodeReading(reading.tempC, reading.minute.toDouble(), reading.anomalous)
        vIdx.add(
            id       = "svec:${reading.minute}",
            vector   = vec,
            metadata = mapOf(
                "minute"    to reading.minute.toString(),
                "temp"      to "%.1f".format(reading.tempC),
                "anomalous" to if (reading.anomalous) "1" else "0",
                "f0"        to "%.6f".format(vec[0]),
                "f1"        to "%.6f".format(vec[1]),
                "f2"        to "%.6f".format(vec[2]),
                "f3"        to "%.6f".format(vec[3]),
            ),
        )

        // Pipeline: velocity + HLL writes — one round-trip for all derived fields.
        val velocity = prevTemp?.let { reading.tempC - it } ?: 0.0
        val cmds = mutableListOf(
            listOf("HSET", "sensor:stats", "temp_velocity", "%.2f".format(velocity))
        )
        if (reading.anomalous) {
            cmds += listOf("PFADD", "sensor:anomaly_hll",      reading.minute.toString())
            cmds += listOf("PFADD", "sensor:anomaly_type_hll", anomalyType(reading.tempC))
        }
        DazzleServer.directPipeline(cmds)
    }

    // ── Detection context (Task 1) ────────────────────────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        // 1. Precompute operational state (1 getDirect — snapshot-cached)
        val kvCtx  = precompute.buildContextBlock(currentMinute, windowMinutes)
        // 2. Velocity: rate-of-change pre-fault signal
        val velCtx = buildVelocityContext()
        // 3. HNSW episodic memory + HFE recent decisions
        val knnCtx = buildKnnContext(currentMinute)
        return listOf(kvCtx, velCtx, knnCtx).filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    private fun buildVelocityContext(): String {
        val vel = stats.getDirect("temp_velocity")?.toDoubleOrNull() ?: return ""
        if (vel < 0.05 && vel > -0.05) return ""
        val dir = if (vel > 0) "rising" else "falling"
        val urgency = when {
            vel >  2.0 -> " — RAPID RISE, approaching fault threshold"
            vel < -2.0 -> " — RAPID DROP, approaching dropout threshold"
            vel >  1.0 -> " — fast rise"
            vel < -1.0 -> " — fast fall"
            else       -> ""
        }
        return "[Temperature Velocity]\n${"%.2f".format(vel)}°C/reading $dir$urgency"
    }

    private fun buildKnnContext(currentMinute: Int): String {
        val latestTemp = stats.getDirect("latest_temp")?.toDoubleOrNull() ?: 20.0
        val isAnom     = latestTemp > 28.0 || latestTemp < 5.0

        val query   = encodeReading(latestTemp, currentMinute.toDouble(), isAnom)
        val results = vIdx.search(query = query, k = KNN_K,
            returnFields = listOf("minute", "temp", "anomalous"))

        val lines = mutableListOf<String>()

        if (results.isNotEmpty()) {
            val faultMatches  = results.filter { it.fields["anomalous"] == "1" }
            val normalMatches = results.filter { it.fields["anomalous"] != "1" }
            val faultPct      = (faultMatches.size * 100) / results.size

            lines += "[Episodic Memory — HNSW k=$KNN_K]"
            val patternDesc = if (faultPct >= 50) "were FAULT events." else "were normal."
            lines += "Pattern signal: $faultPct% of the $KNN_K most similar past readings $patternDesc"
            if (faultMatches.isNotEmpty()) {
                val fm = faultMatches.joinToString(" | ") { "t=${it.fields["minute"]}min ${it.fields["temp"]}°C" }
                lines += "  Fault matches: $fm"
            }
            if (normalMatches.isNotEmpty()) {
                val nm = normalMatches.joinToString(" | ") { "t=${it.fields["minute"]}min ${it.fields["temp"]}°C" }
                lines += "  Normal matches: $nm"
            }
        }

        // HFE agent memory — only non-expired checkpoint decisions are visible.
        val memFields = agentMemory.getAll()
        if (memFields.isNotEmpty()) {
            val sorted = memFields.entries
                .mapNotNull { (k, v) -> k.removePrefix("cp_").toIntOrNull()?.let { it to v } }
                .sortedBy { it.first }
            if (sorted.isNotEmpty()) {
                lines += "[Recent Agent Decisions — HFE decaying memory]"
                for ((idx, decision) in sorted) lines += "  CP${idx + 1}: $decision"
            }
        }

        return lines.joinToString("\n")
    }

    // ── Prediction context (Task 2) — precursor index signal ─────────────

    override fun buildPredictionContext(currentMinute: Int): String {
        val latestTemp = stats.getDirect("latest_temp")?.toDoubleOrNull() ?: 20.0
        val isAnom     = latestTemp > 28.0 || latestTemp < 5.0

        val query   = encodeReading(latestTemp, currentMinute.toDouble(), isAnom)
        val results = precursorIdx.search(query = query, k = PRECURSOR_K,
            returnFields = listOf("pre_minute", "pre_temp", "fault_minute"))

        if (results.isEmpty()) return ""

        val matchPct     = (results.size * 100) / PRECURSOR_K
        val faultSources = results.mapNotNull { it.fields["fault_minute"] }
            .joinToString(" | ") { "fault@t=${it}min" }

        val lines = mutableListOf("[Precursor Memory — confirmed pre-fault signatures, HNSW k=$PRECURSOR_K]")
        lines += "Match rate: $matchPct% of neighbors are confirmed pre-fault readings."
        lines += when {
            matchPct >= 67 -> "HIGH RISK SIGNAL: current profile closely matches pre-fault conditions."
            matchPct >= 33 -> "MODERATE RISK SIGNAL: some similarity to pre-fault conditions."
            else           -> "LOW RISK SIGNAL: current profile differs from known pre-fault patterns."
        }
        if (faultSources.isNotEmpty()) lines += "  Source faults: $faultSources"
        val neighbors = results.joinToString(" | ") { r ->
            "t=${r.fields["pre_minute"] ?: "?"}min ${r.fields["pre_temp"] ?: "?"}°C"
        }
        lines += "  Matching pre-fault readings: $neighbors"
        return lines.joinToString("\n")
    }

    // ── Synthesis context (Task 3) ────────────────────────────────────────

    override fun buildSynthesisContext(): String {
        val parts = mutableListOf<String>()

        // Precompute synthesis: full session stats + anomaly minutes + decisions list
        val base = precompute.buildSynthesisContext()
        if (base.isNotEmpty()) parts += base

        // HFE decisions — may differ from full list if early ones have expired
        val memFields = agentMemory.getAll()
        if (memFields.isNotEmpty()) {
            val sorted = memFields.entries
                .mapNotNull { (k, v) -> k.removePrefix("cp_").toIntOrNull()?.let { it to v } }
                .sortedBy { it.first }
            val memLines = mutableListOf("[Agent Memory — HFE decaying view]")
            for ((idx, decision) in sorted) memLines += "  CP${idx + 1}: $decision"
            parts += memLines.joinToString("\n")
        }

        // HLL: compact anomaly cardinality + pattern diversity
        val uniqueAnomalies = anomalyHLL.count()
        val distinctTypes   = anomalyTypeHLL.count()
        if (uniqueAnomalies > 0) {
            parts += "[Anomaly Profile — HyperLogLog estimates]\n" +
                "Unique fault events: ~$uniqueAnomalies | " +
                "Distinct anomaly patterns: $distinctTypes"
        }

        return parts.joinToString("\n\n")
    }

    // ── Checkpoint decision storage ───────────────────────────────────────

    override fun storeCheckpointDecision(
        index: Int, minute: Int,
        anomalyDetected: Boolean, severity: String, trend: String,
    ) {
        precompute.storeCheckpointDecision(index, minute, anomalyDetected, severity, trend)

        // HFE: store in agent:memory with per-field TTL.
        // Early CPs get shorter TTL so synthesis focuses on recent patterns.
        // CP0 → 30 s, CP1 → 40 s, …, CP9 → 120 s.
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} " +
            "severity=$severity trend=$trend @min=$minute"
        agentMemory.set("cp_$index", decision)
        val ttl = 30L + (index * 10L)
        agentMemory.expireField("cp_$index", ttl)

        if (!anomalyDetected) return

        // Precursor indexing: retroactively add readings from [minute−40, minute−20]
        // to precursorIdx as confirmed pre-fault signatures.
        val start = max(0, minute - PRECURSOR_LOOKBACK_START)
        val end   = max(0, minute - PRECURSOR_LOOKBACK_END)
        for (m in start..end) {
            val hash = dazzle.hash("svec:$m")
            val components = hash.mGetDirect("f0", "f1", "f2", "f3")
            val f0 = components[0]?.toFloatOrNull() ?: continue
            val f1 = components[1]?.toFloatOrNull() ?: continue
            val f2 = components[2]?.toFloatOrNull() ?: continue
            val f3 = components[3]?.toFloatOrNull() ?: continue
            val tempStr = hash.mGetDirect("temp")[0] ?: "?"
            precursorIdx.add(
                id       = "pvec:${minute}_$m",
                vector   = floatArrayOf(f0, f1, f2, f3),
                metadata = mapOf(
                    "pre_minute"  to m.toString(),
                    "pre_temp"    to tempStr,
                    "fault_minute" to minute.toString(),
                ),
            )
        }
    }

    override fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        return (System.nanoTime() - start) / 1_000.0
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private fun encodeReading(tempC: Double, minute: Double, anomalous: Boolean): FloatArray {
        val tempNorm = ((tempC - 20.0) / 20.0).coerceIn(-1.0, 1.0).toFloat()
        val angle    = 2.0 * PI * minute / 200.0
        val anomFlag = if (anomalous || tempC > 28.0 || tempC < 5.0) 1.0f else 0.0f
        return floatArrayOf(tempNorm, sin(angle).toFloat(), cos(angle).toFloat(), anomFlag)
    }

    private fun anomalyType(tempC: Double): String = when {
        tempC > 32.0 -> "spike_high"
        tempC > 28.0 -> "spike_moderate"
        tempC <  2.0 -> "dropout_severe"
        tempC <  5.0 -> "dropout"
        else         -> "oscillation"
    }

    companion object {
        private const val DIM                    = 4
        private const val KNN_K                  = 5
        private const val PRECURSOR_K            = 3
        private const val PRECURSOR_LOOKBACK_START = 40
        private const val PRECURSOR_LOOKBACK_END   = 20
    }
}
