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

import android.util.Log
import dev.dazzle.sdk.Dazzle
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.VectorIndex
import java.util.Locale
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Plan 18 — Dazzle-Vector: the full-stack Valkey 9 edge-AI backend.
 *
 * Integrates every Valkey 9 primitive to maximise all three experiment tasks:
 *
 *   Task 1 — Detection:
 *     • Precompute ctx_block   → session stats, OLS trend, active fault window (1 getDirect)
 *     • Temperature velocity   → rate-of-change signal, pipeline-written on every ingest
 *     • HNSW vIdx KNN-5        → reading-level episodic memory (ingest-time labels only)
 *     • HNSW wvIndex KNN-5     → window-level episodic memory (confirmed at CP time)
 *     • HFE agent:memory       → non-expired checkpoint decisions for decision history
 *
 *   Task 2 — Prediction:
 *     • HNSW precursorIdx KNN-3 → window-level pre-fault signatures, one
 *       vector per confirmed fault (the [fault−40, fault−20] window stats)
 *
 *   Task 3 — Report:
 *     • HyperLogLog ×2         → compact anomaly cardinality + distinct pattern diversity
 *     • HFE agent:memory       → synthesis sees only recent decisions (decaying memory)
 *     • Precompute synthesis    → full anomaly minute list + session stats
 *
 * ## HNSW encoding
 *
 *   Reading index (vIdx, dim=4):
 *     [0] tempNorm  = clamp((tempC − 20) / 20, −1, 1)
 *     [1] minSin    = sin(2π × minute / 200)
 *     [2] minCos    = cos(2π × minute / 200)
 *     [3] anomFlag  = 1.0 if tempC > 28 or < 5 else 0.0
 *
 *   Window index (wvIndex, dim=4):
 *     [0] maxTempNorm   = clamp((windowMaxTemp − 20) / 20, −1, 1)
 *     [1] avgTempNorm   = clamp((windowAvgTemp − 20) / 20, −1, 1)
 *     [2] highFaultFlag = 1.0 if winMax > 28 else 0.0
 *     [3] lowFaultFlag  = 1.0 if winMin < 5  else 0.0
 *     label: window_fault = "1" if winMax > 28 or winMin < 5 else "0"
 *            (physical criterion — decoupled from LLM decision to prevent
 *            auto-contamination of the index by LLM false-positives).
 *     The flags and the label are co-derived from the same winMin/winMax:
 *     (highFaultFlag==1 OR lowFaultFlag==1) ⟺ window_fault=="1".
 *
 *   The binary flags separate fault and non-fault windows in cosine space —
 *   without them, cosine similarity matches direction-only and a mildly-elevated
 *   window (peak 26°C) looks similar to a true fault window (peak 34°C).
 *
 *   Precursor index (precursorIdx, dim=4) — window-level, one vec per fault:
 *     [0] maxNorm    = clamp((preMaxTemp − 20) / 20, −1, 1)
 *     [1] avgNorm    = clamp((preAvgTemp − 20) / 20, −1, 1)
 *     [2] velNorm    = clamp(preVelocity / 2, −1, 1)   (°C per reading)
 *     [3] anomFlag   = 1.0 if preMax > 28 or preMin < 5 else 0.0
 *     Pre-window range: [fault−40, fault−20]. Stored metadata keeps the
 *     source fault minute and the summary stats for LLM context.
 *
 * Requires DazzleModule.VectorSearch in DazzleConfig.modules at server start.
 */
class DazzleVectorIoTValkey9Paper2Manager : StorageBackend {

    override val backendName = "Dazzle-Vector"

    private val dazzle: Dazzle = DazzleServer.client()
    private val stats     = dazzle.hash("sensor:stats")
    private val anomalies = dazzle.sortedSet("sensor:anomalies")

    private val precompute = DazzlePrecomputeIoTManager()
    private var fieldLogCount = 0

    // ── Reading-level HNSW — individual sensor readings ──────────────────
    private val vIdx = dazzle.vectorIndex(
        name        = "sensor:vindex",
        hashPrefix  = "svec:",
        vectorField = "emb",
        dim         = DIM,
        algorithm   = VectorIndex.Algorithm.HNSW,
        metric      = VectorIndex.Metric.COSINE,
    )

    // ── Window-level HNSW — one vector per confirmed checkpoint window ────
    private val wvIndex = dazzle.vectorIndex(
        name        = "sensor:wvindex",
        hashPrefix  = "wvec:",
        vectorField = "emb",
        dim         = DIM,
        algorithm   = VectorIndex.Algorithm.HNSW,
        metric      = VectorIndex.Metric.COSINE,
    )

    // ── Precursor HNSW — confirmed pre-fault signatures ───────────────────
    private val precursorIdx = dazzle.vectorIndex(
        name        = "sensor:pvindex",
        hashPrefix  = "pvec:",
        vectorField = "emb",
        dim         = DIM,
        algorithm   = VectorIndex.Algorithm.HNSW,
        metric      = VectorIndex.Metric.COSINE,
    )

    // ── HyperLogLog — anomaly cardinality (Task 3) ───────────────────────
    private val anomalyHLL     = dazzle.hyperLogLog("sensor:anomaly_hll")
    private val anomalyTypeHLL = dazzle.hyperLogLog("sensor:anomaly_type_hll")

    // ── Exact type counts ─────────────────────────────────────────────────
    private val anomalyTypeCounts = dazzle.hash("sensor:anomaly_type_counts")

    // ── HFE hash — recency-weighted agent decisions (Task 1 + 3) ─────────
    private val agentMemory = dazzle.hash("agent:memory")

    // ── TFI — server-side rule engine + Bayesian online learner (Plan 19)
    private val tfi = dazzle.tfi("sensor:fault-intel")

    init {
        vIdx.create()
        wvIndex.create()
        precursorIdx.create()
        tfi.init()
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun flush() {
        precompute.flush()
        vIdx.drop()
        wvIndex.drop()
        precursorIdx.drop()
        for (prefix in listOf("svec:*", "wvec:*", "pvec:*")) {
            DazzleServer.directCommand(
                "EVAL",
                "local k=redis.call('KEYS','$prefix'); if #k>0 then redis.call('DEL',unpack(k)) end; return #k",
                "0",
            )
        }
        vIdx.create()
        wvIndex.create()
        precursorIdx.create()
        anomalyHLL.deleteKey()
        anomalyTypeHLL.deleteKey()
        anomalyTypeCounts.delete()
        agentMemory.delete()
        tfi.reset()
        tfi.init()
    }

    // ── Ingest ────────────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        val prevTemp = stats.getDirect("latest_temp")?.toDoubleOrNull()

        precompute.ingest(reading)

        val vec = encodeReading(reading.tempC, reading.minute.toDouble(), reading.anomalous)
        vIdx.add(id = "svec:${reading.minute}", vector = vec)
        dazzle.hash("svec:${reading.minute}").setAll(mapOf(
            "minute"    to reading.minute.toString(),
            "temp"      to String.format(Locale.US, "%.1f", reading.tempC),
            "anomalous" to if (reading.anomalous) "1" else "0",
            "status"    to reading.effectiveStatus.name,
            "f0"        to String.format(Locale.US, "%.6f", vec[0]),
            "f1"        to String.format(Locale.US, "%.6f", vec[1]),
            "f2"        to String.format(Locale.US, "%.6f", vec[2]),
            "f3"        to String.format(Locale.US, "%.6f", vec[3]),
        ))

        // Feed TFI with the reading's NAMUR status so its rolling flicker /
        // out-of-range / fault-reported counters update in C.
        tfi.ingest(reading.minute, reading.tempC, reading.effectiveStatus.name)

        // Debug: print non-OK statuses so we can verify flickers reach TFI.
        if (reading.effectiveStatus != SensorStatus.OK) {
            Log.i("TfiDebug", "ingested status: min=${reading.minute} status=${reading.effectiveStatus.name} rawStatusCode=${reading.statusCode}")
        }

        val velocity = prevTemp?.let { reading.tempC - it } ?: 0.0
        val cmds = mutableListOf(
            listOf("HSET", "sensor:stats", "temp_velocity", String.format(Locale.US, "%.2f", velocity)),
        )
        if (reading.anomalous) {
            val type = anomalyType(reading.tempC)
            cmds += listOf("PFADD",   "sensor:anomaly_hll",        reading.minute.toString())
            cmds += listOf("PFADD",   "sensor:anomaly_type_hll",   type)
            cmds += listOf("HINCRBY", "sensor:anomaly_type_counts", type, "1")
        }
        DazzleServer.directPipeline(cmds)
    }

    // ── Detection context (Task 1) ────────────────────────────────────────

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val kvCtx  = precompute.buildContextBlock(currentMinute, windowMinutes)
        val velCtx = buildVelocityContext()
        val hasActiveFaultWindow = kvCtx.contains("Active fault window")
        val knnCtx = buildKnnContext(currentMinute, hasActiveFaultWindow)
        return listOf(kvCtx, velCtx, knnCtx).filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    internal fun buildVelocityContext(): String {
        val vel = (stats.getDirect("temp_velocity") ?: stats.get("temp_velocity"))?.toDoubleOrNull() ?: return ""
        if (vel < 0.05 && vel > -0.05) return ""
        val dir = if (vel > 0) "rising" else "falling"
        val currentTemp = (stats.getDirect("latest_temp") ?: stats.get("latest_temp"))?.toDoubleOrNull() ?: 20.0
        val nearHighFault = currentTemp >= 25.0
        val nearLowFault  = currentTemp <= 8.0
        val urgency = when {
            vel >  2.0 && nearHighFault -> " — RAPID RISE, approaching fault threshold"
            vel < -2.0 && nearLowFault  -> " — RAPID DROP, approaching dropout threshold"
            vel >  2.0                  -> " — rapid rise (temp still in normal range)"
            vel < -2.0                  -> " — rapid drop (temp still in normal range)"
            vel >  1.0 -> " — fast rise"
            vel < -1.0 -> " — fast fall"
            else       -> ""
        }
        return "[Temperature Velocity]\n${String.format(Locale.US, "%.2f", vel)}°C/reading $dir$urgency"
    }

    internal fun buildKnnContext(currentMinute: Int, hasActiveFaultWindow: Boolean = false): String {
        val latestTemp = (stats.getDirect("latest_temp") ?: stats.get("latest_temp"))?.toDoubleOrNull() ?: 20.0
        val isAnom     = latestTemp > 28.0 || latestTemp < 5.0

        // ── Reading-level KNN ─────────────────────────────────────────────
        val readingQuery = encodeReading(latestTemp, currentMinute.toDouble(), isAnom)
        val rawResults   = vIdx.search(query = readingQuery, k = KNN_K)
        if (rawResults.isNotEmpty() && fieldLogCount < 3) {
            fieldLogCount++
            val p = dazzle.hash(rawResults[0].id).mGet("minute", "temp", "anomalous")
            Log.d("DazzleVec", "mGet[$fieldLogCount] id=${rawResults[0].id} min=${p[0]} temp=${p[1]} anom=${p[2]}")
        }
        val results = rawResults.filter { it.score <= MIN_KNN_SCORE }

        // ── Window-level KNN ─────────────────────────────────────────────
        val (winMin, winMax, winAvg) = windowStats(currentMinute)
        val windowQuery   = encodeWindow(winMin, winMax, winAvg)
        val rawWinResults = wvIndex.search(query = windowQuery, k = WINDOW_KNN_K)
        val winResults    = rawWinResults.filter { it.score <= MIN_KNN_SCORE }

        // ── HFE — read early for cascade detection ────────────────────────
        val memFields = agentMemory.getAll()
        val hfeSorted = memFields.entries
            .mapNotNull { (k, v) -> k.removePrefix("cp_").toIntOrNull()?.let { it to v } }
            .sortedBy { it.first }
        val hfeHasRecentFault = hfeSorted.any { it.second.contains("anomaly=yes") }

        val lines    = mutableListOf<String>()
        var faultPct = 0
        var windowFaultPct = 0

        // ── Emit reading-level section ────────────────────────────────────
        if (results.isNotEmpty()) {
            data class KnnEntry(val minute: Int, val temp: String, val anomalous: Boolean)
            val entries = results.mapNotNull { r ->
                val vals = dazzle.hash(r.id).mGet("minute", "temp", "anomalous")
                val min  = vals[0]?.toIntOrNull() ?: return@mapNotNull null
                KnnEntry(min, vals[1] ?: "?", vals[2] == "1")
            }
            val faultMatches  = entries.filter { it.anomalous }
            val normalMatches = entries.filter { !it.anomalous }
            faultPct = if (entries.isNotEmpty()) (faultMatches.size * 100) / entries.size else 0

            lines += "[Episodic Memory — HNSW k=$KNN_K]"
            lines += "Pattern signal: $faultPct% of the $KNN_K most similar past readings were FAULT events (${100 - faultPct}% normal)."
            if (faultMatches.isNotEmpty()) {
                lines += "  Fault matches: ${faultMatches.joinToString(" | ") { "t=${it.minute}min ${it.temp}°C" }}"
            }
            if (normalMatches.isNotEmpty()) {
                lines += "  Normal matches: ${normalMatches.joinToString(" | ") { "t=${it.minute}min ${it.temp}°C" }}"
            }
        }

        // ── Emit window-level section ─────────────────────────────────────
        if (winResults.isNotEmpty()) {
            data class WinEntry(val minute: Int, val maxTemp: String, val avgTemp: String, val fault: Boolean)
            val winEntries = winResults.mapNotNull { r ->
                val vals = dazzle.hash(r.id).mGet("minute", "max_temp", "avg_temp", "window_fault")
                val min = vals[0]?.toIntOrNull() ?: return@mapNotNull null
                WinEntry(min, vals[1] ?: "?", vals[2] ?: "?", vals[3] == "1")
            }
            val winFault  = winEntries.filter { it.fault }
            val winNormal = winEntries.filter { !it.fault }
            windowFaultPct = if (winEntries.isNotEmpty()) (winFault.size * 100) / winEntries.size else 0

            if (results.isNotEmpty()) lines += ""  // blank separator
            else lines += "[Episodic Memory — HNSW k=$KNN_K]"

            lines += "Window signal: $windowFaultPct% of the $WINDOW_KNN_K most similar past windows were FAULT windows (${100 - windowFaultPct}% normal)."
            if (winFault.isNotEmpty()) {
                lines += "  Fault windows: ${winFault.joinToString(" | ") { "t=${it.minute}min peak=${it.maxTemp}°C avg=${it.avgTemp}°C" }}"
            }
            if (winNormal.isNotEmpty()) {
                lines += "  Normal windows: ${winNormal.joinToString(" | ") { "t=${it.minute}min peak=${it.maxTemp}°C" }}"
            }
        }

        // ── Unified MEMORY ASSESSMENT ─────────────────────────────────────
        val hasKnnData = results.isNotEmpty() || winResults.isNotEmpty()
        if (hasKnnData) {
            val assessment = when {
                hasActiveFaultWindow ->
                    "MEMORY ASSESSMENT: [Sensor State] confirms ACTIVE FAULT WINDOW — trust Sensor State over episodic memory."

                windowFaultPct >= 60 && faultPct == 0 ->
                    "MEMORY ASSESSMENT: current reading matches normal profile, but this window's peak (${
                        String.format(Locale.US, "%.1f", winMax)
                    }°C) closely matches ${windowFaultPct}% of past FAULT windows — window-level signal indicates fault pattern."

                windowFaultPct >= 60 && faultPct >= 40 ->
                    "MEMORY ASSESSMENT: both reading ($faultPct%) and window ($windowFaultPct%) signals indicate FAULT conditions — strong convergent evidence."

                faultPct >= 60 ->
                    "MEMORY ASSESSMENT: current reading profile closely matches FAULT conditions — high fault signal from episodic memory."

                faultPct == 0 && windowFaultPct == 0 && hfeHasRecentFault ->
                    "MEMORY ASSESSMENT: KNN shows 0% fault pattern (reading and window) — fault decisions in agent memory are from an EARLIER closed window."

                faultPct == 0 && windowFaultPct == 0 ->
                    "MEMORY ASSESSMENT: current sensor profile matches only NORMAL historical readings — no fault pattern in episodic memory."

                else -> ""
            }
            if (assessment.isNotEmpty()) lines += assessment
        }

        // ── HFE decisions with [RESOLVED] cascade tag ─────────────────────
        if (hfeSorted.isNotEmpty()) {
            val cascadeActive = !hasActiveFaultWindow && faultPct == 0 && hfeHasRecentFault
            lines += "[Recent Agent Decisions — HFE decaying memory]"
            for ((idx, decision) in hfeSorted) {
                val tag = if (cascadeActive && decision.contains("anomaly=yes")) "[RESOLVED] " else ""
                lines += "  CP${idx + 1}: $tag$decision"
            }
        }

        return lines.joinToString("\n")
    }

    // ── Prediction context (Task 2) — focused predictive signals ──────────

    /**
     * Builds a compact, prediction-focused context block. Unlike the detection
     * context, this block excludes most of the "current state is normal" signals
     * that otherwise anchor the LLM on the present state. Prediction needs to
     * reason about the FUTURE; three complementary signals feed that reasoning:
     *
     *   1. Current Brief — minimal snapshot so the LLM knows the query time
     *      (one line: temp + velocity + window range). Nothing more.
     *
     *   2. Fault History — statistical priors derived from confirmed faults:
     *      minute list, count, average inter-fault interval, time since last.
     *      Universal signal for any time-series fault process, not dataset-
     *      specific: "past faults happened roughly every N readings" is
     *      information any engineer would want for forecasting.
     *
     *   3. Precursor KNN — pattern-match against indexed pre-fault windows
     *      (cosine similarity on [maxNorm, avgNorm, velNorm, anomFlag]).
     *
     * We do NOT emit aggressive "HIGH/MODERATE/LOW RISK" assessments — raw
     * numbers let the LLM weigh evidence. Heuristic risk labels that fire on
     * every recent-fault case inflate FPRs (cluster of 2 faults does not
     * necessarily mean a third).
     */
    override fun buildPredictionContext(currentMinute: Int): String {
        val sections = mutableListOf<String>()

        // ── 1. Current Brief (with explicit physical state) ───────────────
        val (qMin, qMax, qAvg) = windowStats(currentMinute)
        val qVel = windowVelocity(currentMinute)
        val currentTemp = (stats.getDirect("latest_temp") ?: stats.get("latest_temp"))?.toDoubleOrNull() ?: qAvg
        // Physical state — the single most important signal for cluster-
        // continuation reasoning. Computed from physical thresholds, same as
        // wvIndex window_fault label.
        val physicalState = when {
            qMax > 28.0 -> "FAULT_HIGH (window crossed upper threshold — currently faulting)"
            qMin <  5.0 -> "FAULT_LOW (window crossed lower threshold — currently faulting)"
            qMax > 26.0 -> "ELEVATED (window peak approaching upper threshold)"
            qMin <  8.0 -> "COOL (window low near lower threshold)"
            else        -> "NORMAL (window within safe range)"
        }
        sections += buildString {
            appendLine("[Current Brief at t=${currentMinute}min]")
            appendLine("Reading: ${String.format(Locale.US, "%.1f", currentTemp)}°C")
            appendLine("Window [t-19..t] stats: min=${String.format(Locale.US, "%.1f", qMin)}°C max=${String.format(Locale.US, "%.1f", qMax)}°C avg=${String.format(Locale.US, "%.1f", qAvg)}°C velocity=${String.format(Locale.US, "%+.2f", qVel)}°C/reading")
            appendLine("State: $physicalState")
        }.trimEnd()

        // ── 2. Fault History (with recent density signal) ─────────────────
        val historyRaw = stats.get("precursor_fault_history") ?: ""
        val history = historyRaw.split(",").mapNotNull { it.toIntOrNull() }
        if (history.isNotEmpty()) {
            val faultCount = history.size
            val lastFaultMin = history.last()
            val timeSinceLast = currentMinute - lastFaultMin
            val avgInterval = if (history.size >= 2) {
                (history.last() - history.first()) / (history.size - 1)
            } else -1
            // Recent density: faults within the last 3 CPs (60 readings).
            // Critical cluster signal — when multiple faults cluster, the next
            // window's risk elevates. Raw count, no assessment — LLM decides.
            val recentFaults = history.count { currentMinute - it <= 60 }

            sections += buildString {
                appendLine("[Fault History]")
                appendLine("Confirmed faults so far: $faultCount")
                appendLine("Fault minutes: ${history.joinToString(", ")}")
                appendLine("Last fault: t=${lastFaultMin}min (${timeSinceLast} readings ago)")
                if (avgInterval > 0) {
                    appendLine("Average inter-fault interval: $avgInterval readings")
                }
                appendLine("Faults in last 3 checkpoints (~60 readings): $recentFaults")
            }.trimEnd()
        }

        // ── 3. Precursor KNN ──────────────────────────────────────────────
        val query      = encodePrecursor(qMin, qMax, qAvg, qVel)
        val rawResults = precursorIdx.search(query = query, k = PRECURSOR_K)
        val results    = rawResults.filter { it.score <= MIN_KNN_SCORE }
        if (results.isNotEmpty()) {
            data class PrecEntry(val faultMinute: String, val preMaxTemp: String, val preVelocity: String)
            val entries = results.mapNotNull { r ->
                val vals = dazzle.hash(r.id).mGet("fault_minute", "pre_max_temp", "pre_velocity")
                PrecEntry(vals[0] ?: return@mapNotNull null, vals[1] ?: "?", vals[2] ?: "?")
            }
            if (entries.isNotEmpty()) {
                val indexSize = history.size
                val effectiveK = min(PRECURSOR_K, indexSize)
                val matchPct = if (effectiveK > 0) (entries.size * 100) / effectiveK else 0
                sections += buildString {
                    appendLine("[Precursor Memory — HNSW k=$PRECURSOR_K over $indexSize indexed pre-fault windows]")
                    appendLine("Match rate: $matchPct% (${entries.size} of $effectiveK closest neighbors match current profile).")
                    appendLine("Matching source faults: ${entries.joinToString(" | ") { "fault@t=${it.faultMinute}min (pre_peak=${it.preMaxTemp}°C vel=${it.preVelocity})" }}")
                }.trimEnd()
            }
        }

        return sections.joinToString("\n\n")
    }

    // ── Synthesis context (Task 3) ────────────────────────────────────────

    override fun buildSynthesisContext(): String {
        val parts = mutableListOf<String>()

        val base = precompute.buildSynthesisContext()
        if (base.isNotEmpty()) parts += base

        val memFields = agentMemory.getAll()
        if (memFields.isNotEmpty()) {
            val sorted = memFields.entries
                .mapNotNull { (k, v) -> k.removePrefix("cp_").toIntOrNull()?.let { it to v } }
                .sortedBy { it.first }
            parts += sorted.joinToString("\n", "[Agent Memory — HFE decaying view]\n") { (idx, v) -> "  CP${idx + 1}: $v" }
        }

        val uniqueAnomalies = anomalyHLL.count()
        if (uniqueAnomalies > 0) {
            val typeCounts = anomalyTypeCounts.getAll()
            val typeList = typeCounts.entries
                .sortedByDescending { it.value.toLongOrNull() ?: 0L }
                .joinToString(", ") { "${it.key}(${it.value}×)" }
            parts += "[Anomaly Profile]\nTotal fault readings (HLL): ~$uniqueAnomalies | Types: $typeList"
        }

        return parts.joinToString("\n\n")
    }

    // ── Checkpoint decision storage ───────────────────────────────────────

    override fun storeCheckpointDecision(
        index: Int, minute: Int,
        anomalyDetected: Boolean, severity: String, trend: String,
    ) {
        precompute.storeCheckpointDecision(index, minute, anomalyDetected, severity, trend)

        // HFE: per-field TTL — CP0→30s, CP1→40s, …, CP9→120s.
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} severity=$severity trend=$trend @min=$minute"
        agentMemory.set("cp_$index", decision)
        agentMemory.expireField("cp_$index", 30L + (index * 10L))

        // ── Window-level index — always, regardless of fault status ───────
        // Build the window summary vector from readings in [minute-WINDOW+1, minute]
        // and add it to wvIndex labelled by PHYSICAL fault criterion, not LLM
        // decision. Using LLM decision here lets any LLM false-positive pollute
        // the wvIndex for all future queries (auto-contamination); using the
        // physical threshold keeps the index self-correcting.
        val (winMin, winMax, winAvg) = windowStats(minute)
        val physicalFault = winMax > 28.0 || winMin < 5.0
        val wvec    = encodeWindow(winMin, winMax, winAvg)
        val wvecKey = "wvec:$minute"
        wvIndex.add(id = wvecKey, vector = wvec)
        dazzle.hash(wvecKey).setAll(mapOf(
            "minute"       to minute.toString(),
            "max_temp"     to String.format(Locale.US, "%.1f", winMax),
            "avg_temp"     to String.format(Locale.US, "%.1f", winAvg),
            "window_fault" to if (physicalFault) "1" else "0",
        ))

        if (!anomalyDetected) return

        // Notify TFI: a fault was confirmed at this minute. TFI appends it
        // to its event stream for use by cluster-density / interval signals.
        tfi.event(minute, severity = severity)

        // ── Precursor indexing (window-level) ─────────────────────────────
        // Index ONE pre-fault window summary per confirmed fault: the window
        // [minute−40, minute−20] — readings that preceded this fault. Future
        // queries compare current window stats against these signatures to
        // detect patterns similar to past pre-fault conditions.
        val historyRaw = stats.get("precursor_fault_history") ?: ""
        val history = historyRaw.split(",").mapNotNull { it.toIntOrNull() }.toMutableList()
        while (history.size >= MAX_PRECURSOR_SOURCES) {
            val evict = history.removeAt(0)
            DazzleServer.directCommand("DEL", "pvec:$evict")
        }
        history += minute
        stats.set("precursor_fault_history", history.joinToString(","))

        val preStart = max(0, minute - PRECURSOR_LOOKBACK_START)
        val preEnd   = max(0, minute - PRECURSOR_LOOKBACK_END)
        val preTemps = (preStart..preEnd).mapNotNull { m ->
            dazzle.hash("svec:$m").mGet("temp")[0]?.toDoubleOrNull()
        }
        if (preTemps.isEmpty()) return
        val preMin = preTemps.min()
        val preMax = preTemps.max()
        val preAvg = preTemps.average()
        val preVel = (preTemps.last() - preTemps.first()) / preTemps.size.toDouble()

        val pvec    = encodePrecursor(preMin, preMax, preAvg, preVel)
        val pvecKey = "pvec:$minute"
        precursorIdx.add(id = pvecKey, vector = pvec)
        dazzle.hash(pvecKey).setAll(mapOf(
            "fault_minute" to minute.toString(),
            "pre_min_temp" to String.format(Locale.US, "%.1f", preMin),
            "pre_max_temp" to String.format(Locale.US, "%.1f", preMax),
            "pre_avg_temp" to String.format(Locale.US, "%.1f", preAvg),
            "pre_velocity" to String.format(Locale.US, "%.2f", preVel),
        ))
    }

    // ── Rule-based fault risk (Task 2 companion to LLM prediction) ───────

    override fun computeRuleBasedRisk(currentMinute: Int): FaultRiskAssessment {
        val (qMin, qMax, qAvg) = windowStats(currentMinute)
        val qVel = windowVelocity(currentMinute)
        val historyRaw = stats.get("precursor_fault_history") ?: ""
        val history = historyRaw.split(",").mapNotNull { it.toIntOrNull() }

        // Compute precursor match pct same way as buildPredictionContext so
        // both prompt output and the engine see the same signal.
        val query      = encodePrecursor(qMin, qMax, qAvg, qVel)
        val rawResults = precursorIdx.search(query = query, k = PRECURSOR_K)
        val results    = rawResults.filter { it.score <= MIN_KNN_SCORE }
        val effectiveK = if (history.isEmpty()) PRECURSOR_K else min(PRECURSOR_K, history.size)
        val precMatchPct = if (effectiveK > 0) (results.size * 100) / effectiveK else 0

        // Delegate to the TFI Dazzle module (server-side C rule engine +
        // online Bayesian learner). TFI has visibility of both the seed
        // signals and the NAMUR status-code signals fed via tfi.ingest(),
        // so its output subsumes the in-process FaultRiskEngine.
        val tfiAssess = tfi.score(
            atMinute          = currentMinute,
            winMin            = qMin,
            winMax            = qMax,
            winAvg            = qAvg,
            winVelocity       = qVel,
            precursorMatchPct = precMatchPct,
        )

        return FaultRiskAssessment(
            probability          = tfiAssess.probability,
            predicted            = tfiAssess.predicted,
            baseRate             = tfiAssess.baseRate,
            clusterDensity       = tfiAssess.clusterDensity,
            intervalRatio        = tfiAssess.intervalRatio,
            precursorMatchPct    = tfiAssess.precursorMatchPct,
            currentPhysicalState = tfiAssess.physicalState,
            firedSignals         = tfiAssess.firedSignals,
        )
    }

    override fun observeActualFault(actualFault: Boolean) {
        // Bayesian posterior update in the TFI engine — uses the fired
        // signal set cached by the most recent computeRuleBasedRisk call.
        tfi.observe(actualFault)
    }

    override fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        return (System.nanoTime() - start) / 1_000.0
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /** Compute the (min, max, average) temperature across the current window. */
    private fun windowStats(currentMinute: Int): Triple<Double, Double, Double> {
        val start = max(0, currentMinute - WINDOW_MINUTES + 1)
        val temps = (start..currentMinute).mapNotNull { m ->
            dazzle.hash("svec:$m").mGet("temp")[0]?.toDoubleOrNull()
        }
        return if (temps.isEmpty()) Triple(20.0, 20.0, 20.0)
        else   Triple(temps.min(), temps.max(), temps.average())
    }

    /** Mean temperature velocity (°C per reading) across the current window. */
    private fun windowVelocity(currentMinute: Int): Double {
        val start = max(0, currentMinute - WINDOW_MINUTES + 1)
        val temps = (start..currentMinute).mapNotNull { m ->
            dazzle.hash("svec:$m").mGet("temp")[0]?.toDoubleOrNull()
        }
        return if (temps.size < 2) 0.0
        else (temps.last() - temps.first()) / temps.size.toDouble()
    }

    private fun encodeReading(tempC: Double, minute: Double, anomalous: Boolean): FloatArray {
        val tempNorm = ((tempC - 20.0) / 20.0).coerceIn(-1.0, 1.0).toFloat()
        val angle    = 2.0 * PI * minute / 200.0
        val anomFlag = if (anomalous || tempC > 28.0 || tempC < 5.0) 1.0f else 0.0f
        return floatArrayOf(tempNorm, sin(angle).toFloat(), cos(angle).toFloat(), anomFlag)
    }

    /**
     * Pre-fault window signature vector: (maxNorm, avgNorm, velNorm, anomFlag).
     *
     * velNorm captures the temperature trend (rising/falling) in the window —
     * a key predictive signal when the fault develops gradually. anomFlag is
     * rarely 1 here (pre-windows precede the fault), but exists to allow the
     * LLM to recognise "cluster" patterns where anomalies precede each other.
     * Temporal position excluded for profile-based matching.
     */
    private fun encodePrecursor(minTempC: Double, maxTempC: Double, avgTempC: Double, velocity: Double): FloatArray {
        val maxNorm  = ((maxTempC - 20.0) / 20.0).coerceIn(-1.0, 1.0).toFloat()
        val avgNorm  = ((avgTempC - 20.0) / 20.0).coerceIn(-1.0, 1.0).toFloat()
        val velNorm  = (velocity / 2.0).coerceIn(-1.0, 1.0).toFloat()       // 2°C/reading → ±1
        val anomFlag = if (maxTempC > 28.0 || minTempC < 5.0) 1.0f else 0.0f
        return floatArrayOf(maxNorm, avgNorm, velNorm, anomFlag)
    }

    /**
     * Window summary vector: peak temp + avg temp + binary fault flags.
     *
     * Cosine similarity measures direction, not magnitude — a window with peak
     * 26°C and one with peak 34°C point in similar directions in a pure-magnitude
     * encoding. The binary flags act as a hard separator: fault windows live in
     * a distinct subspace (flag=1) from normal/mildly-elevated windows (flag=0),
     * so cosine distance between fault and non-fault exceeds the match threshold.
     *
     * Flag semantics must match the `window_fault` metadata physical criterion:
     *   highFaultFlag = 1 iff maxTempC > 28  (any reading crossed high threshold)
     *   lowFaultFlag  = 1 iff minTempC <  5  (any reading crossed low threshold)
     *   window_fault  = "1" iff highFaultFlag==1 OR lowFaultFlag==1
     *
     * Temporal position is intentionally excluded — we want windows with similar
     * temperature PROFILES to match, regardless of when they occurred.
     */
    private fun encodeWindow(minTempC: Double, maxTempC: Double, avgTempC: Double): FloatArray {
        val maxNorm       = ((maxTempC - 20.0) / 20.0).coerceIn(-1.0, 1.0).toFloat()
        val avgNorm       = ((avgTempC - 20.0) / 20.0).coerceIn(-1.0, 1.0).toFloat()
        val highFaultFlag = if (maxTempC > 28.0) 1.0f else 0.0f
        val lowFaultFlag  = if (minTempC <  5.0) 1.0f else 0.0f
        return floatArrayOf(maxNorm, avgNorm, highFaultFlag, lowFaultFlag)
    }

    private fun anomalyType(tempC: Double): String = when {
        tempC > 32.0 -> "spike_high"
        tempC > 28.0 -> "spike_moderate"
        tempC <  2.0 -> "dropout_severe"
        tempC <  5.0 -> "dropout"
        else         -> "oscillation"
    }

    companion object {
        private const val DIM                      = 4
        private const val KNN_K                    = 5
        private const val WINDOW_KNN_K             = 5
        private const val WINDOW_MINUTES           = 20
        private const val PRECURSOR_K              = 3
        private const val PRECURSOR_LOOKBACK_START = 40
        private const val PRECURSOR_LOOKBACK_END   = 20
        private const val MAX_PRECURSOR_SOURCES    = 8
        private const val MIN_KNN_SCORE            = 0.35f
    }
}
