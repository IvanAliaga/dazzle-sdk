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

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.util.Log
import com.google.gson.GsonBuilder
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.WipeTarget
import java.io.File

/**
 * ExperimentPipelineIoTValkey8 v2 — Three-Task Sequential Monitoring Agent
 *
 * Evaluates three distinct capabilities of an LLM agent backed by Dazzle:
 *
 *   Task 1 — DETECTION   : Fault classification per checkpoint.
 *             Threshold crossing is pre-computed; the agent classifies
 *             severity. Without memory: conservative (all "none").
 *             With memory: similar past faults calibrate severity.
 *
 *   Task 2 — PREDICTION  : Risk forecast for the NEXT 20-minute window.
 *             Without memory: random guess. With vector memory: agent
 *             recalls that similar sensor profiles preceded faults and
 *             raises the predicted risk accordingly.
 *
 *   Task 3 — REPORT      : Cumulative maintenance report at session end.
 *             Without Dazzle: agent has no session state, hallucinates
 *             statistics. With Dazzle (precompute KV): accurate counts,
 *             ranges, and fault timeline.
 *
 * Dataset: dataset_iot_valkey8.json — 400 readings, 20 checkpoints, 10 fault
 * events (5 pattern types × 2 occurrences) designed to stress memory.
 */
class ExperimentPipelineIoTValkey8(
    private val context: Context,
    private val modelPath: String,
    private val backendName: String = "dazzle-precompute",
    private val onProgress: (current: Int, total: Int, message: String) -> Unit = { _, _, _ -> },
) {

    private val gson = GsonBuilder().setPrettyPrinting().create()

    // ─────────────────────────────────────────────────────────────────────────
    // Result types
    // ─────────────────────────────────────────────────────────────────────────

    data class AnomalyDecision(
        val detected: Boolean,
        val severity: String,
        val trend: String,
        val rawJson: String,
    )

    data class RiskPrediction(
        val riskPct: Int,          // 0–100
        val riskLevel: String,     // low / medium / high
        val rawJson: String,
        val nextWindowHasFault: Boolean,
        val predictionCorrect: Boolean,
    )

    data class CheckpointResult(
        val cpIndex: Int,
        val minute: Int,
        val windowHasAnomaly: Boolean,
        // Task 1 — detection
        val stateless: AnomalyDecision,
        val augmented: AnomalyDecision,
        // Task 2 — prediction (augmented only; stateless has no history)
        val prediction: RiskPrediction?,
        val backendLatencyUs: Double,
        val inferenceMsA: Long,
        val inferenceMsB: Long,
        val promptTokensA: Int,
        val promptTokensB: Int,
        val promptTokensPred: Int,
    )

    data class SynthesisScore(
        val anomalyCountCorrect: Boolean,
        val maxTempCorrect: Boolean,
        val dropoutMentioned: Boolean,
        val anomalyCountExtracted: Int?,
        val maxTempExtracted: Double?,
    ) {
        val total: Int
            get() = listOf(anomalyCountCorrect, maxTempCorrect, dropoutMentioned).count { it }
    }

    data class ReportScore(
        val faultCountCorrect: Boolean,
        val maxTempCorrect: Boolean,
        val minTempCorrect: Boolean,
        val patternsIdentified: Int,   // how many of the 5 fault types mentioned
        val consistencyScore: Int,     // 0–3: count,maxTemp,minTemp
        val raw: String,
    )

    data class GroundTruth(
        val totalAnomalies: Int,
        val maxTemp: Double,
        val minTemp: Double,
        val anomalyMinutes: List<Int>,
    )

    data class ExperimentResults(
        val device: String,
        val model: String,
        val platform: String,
        val checkpoints: List<CheckpointResult>,
        // Task 3 — cumulative report
        val reportStateless: ReportScore,
        val reportAugmented: ReportScore,
        // Legacy synthesis for cross-run comparison
        val synthesis: Map<String, Any>,
        val groundTruth: GroundTruth,
        val batteryBefore: Map<String, Any?>? = null,
        val batteryAfter: Map<String, Any?>? = null,
    )

    // ─────────────────────────────────────────────────────────────────────────
    // Run
    // ─────────────────────────────────────────────────────────────────────────

    fun run(): ExperimentResults {
        fun ensureServerRunning(modules: Set<DazzleModule> = emptySet()) {
            if (!DazzleServer.isRunning()) {
                DazzleServer.start(
                    context,
                    DazzleConfig(
                        port        = 6380,
                        persistence = DazzlePersistence.None,
                        wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
                        modules     = modules,
                    )
                )
                Thread.sleep(800)
            } else if (modules.isNotEmpty()) {
                DazzleServer.stop()
                Thread.sleep(200)
                DazzleServer.start(
                    context,
                    DazzleConfig(
                        port        = 6380,
                        persistence = DazzlePersistence.None,
                        wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
                        modules     = modules,
                    )
                )
                Thread.sleep(800)
            }
        }

        val storage: StorageBackend = when (backendName.lowercase()) {
            "dazzle", "dazzle-lua", "dazzle-pipeline", "dazzle-hfe",
            "dazzle-hll", "dazzle-precompute" -> {
                ensureServerRunning()
                when (backendName.lowercase()) {
                    "dazzle-lua"        -> DazzleLuaContextManager()
                    "dazzle-pipeline"   -> DazzlePipelineContextManager()
                    "dazzle-hfe"        -> DazzleHFEContextManager()
                    "dazzle-hll"        -> DazzleHLLContextManager()
                    else                -> DazzlePrecomputeIoTManager()
                }
            }
            "dazzle-vector" -> {
                ensureServerRunning(modules = setOf(DazzleModule.VectorSearch))
                DazzleVectorIoTValkey8Manager()
            }
            "valkey"    -> { ensureServerRunning(); ValkeyContextManager() }
            "sqlite"    -> SqliteContextManager(context)
            "sqlite-optimized" -> SqliteOptimizedContextManager(context)
            "sqlite-precompute" -> SqlitePrecomputeContextManager(context)
            "objectbox" -> ObjectBoxContextManager(context)
            "lmdb"      -> LmdbContextManager(context)
            "rocksdb"   -> RocksDbContextManager(context)
            "inmemory"  -> InMemoryContextManager()
            else -> throw IllegalArgumentException(
                "Unknown backend '$backendName'. Supported: dazzle, dazzle-{lua,pipeline,hfe,hll,precompute,vector}, valkey, sqlite, sqlite-{optimized,precompute}, objectbox, lmdb, rocksdb, inmemory"
            )
        }
        Log.i(TAG, "Storage backend: ${storage.backendName}")

        val batteryBefore = snapshotBattery()
        val dataset = DatasetLoader.load(context, "dataset_iot_valkey8.json")
        val numCPs  = dataset.checkpointIndices.size
        val total   = numCPs * 3 + 2   // A + B + Prediction passes + 2 synthesis/report

        onProgress(0, total, "Loading Gemma model…")
        val gemma = GemmaInference(context, modelPath)
        storage.flush()

        // ── Condition A: Stateless detection ────────────────────────────────
        onProgress(0, total, "── Task 1A: Stateless fault detection ──")
        val statelessDecisions = mutableListOf<AnomalyDecision>()
        val resultsA = mutableListOf<GemmaInference.InferenceResult>()

        for (cpIdx in 0 until numCPs) {
            val cpReading = dataset.readings[dataset.checkpointIndices[cpIdx]]
            val window    = dataset.window(cpIdx)
            onProgress(cpIdx, total, "[A] CP${cpIdx+1}/$numCPs min=${cpReading.minute}")
            val prompt = buildDetectionPrompt(cpReading, window, context = null)
            val res = runCatching { gemma.generateRaw(prompt) }.getOrElse { fallbackResult() }
            resultsA.add(res)
            statelessDecisions.add(parseAnomalyDecision(res.rawOutput))
        }

        // ── Condition B: Dazzle-augmented detection + prediction ─────────────
        onProgress(numCPs, total, "── Task 1B + 2: Augmented detection & prediction ──")
        val augmentedDecisions  = mutableListOf<AnomalyDecision>()
        val predictions         = mutableListOf<RiskPrediction?>()
        val resultsB            = mutableListOf<GemmaInference.InferenceResult>()
        val resultsPred         = mutableListOf<GemmaInference.InferenceResult>()
        val backendLatencies    = mutableListOf<Double>()
        var lastIngested        = -1

        for (cpIdx in 0 until numCPs) {
            val cpEndIdx  = dataset.checkpointIndices[cpIdx]
            val cpReading = dataset.readings[cpEndIdx]
            onProgress(numCPs + cpIdx, total,
                "[B] CP${cpIdx+1}/$numCPs min=${cpReading.minute}")

            for (j in (lastIngested + 1)..cpEndIdx) storage.ingest(dataset.readings[j])
            lastIngested = cpEndIdx

            val latencyUs    = storage.measureRetrievalLatency(cpReading.minute)
            backendLatencies.add(latencyUs)

            // Task 1B — detection with context
            val contextBlock = storage.buildContextBlock(cpReading.minute)
            val window       = dataset.window(cpIdx)
            val promptB      = buildDetectionPrompt(cpReading, window, contextBlock)
            val resB = runCatching { gemma.generateRaw(promptB) }.getOrElse { fallbackResult() }
            resultsB.add(resB)
            val decision = parseAnomalyDecision(resB.rawOutput)
            augmentedDecisions.add(decision)

            storage.storeCheckpointDecision(
                index           = cpIdx,
                minute          = cpReading.minute,
                anomalyDetected = decision.detected,
                severity        = decision.severity,
                trend           = decision.trend,
            )

            // Task 2 — risk prediction (augmented only)
            val nextHasFault   = if (cpIdx + 1 < numCPs) dataset.windowHasAnomaly(cpIdx + 1) else false
            val predCtxMain    = storage.buildContextBlock(cpReading.minute)
            val predCtxPrec    = storage.buildPredictionContext(cpReading.minute)
            val predContext     = listOf(predCtxMain, predCtxPrec).filter { it.isNotEmpty() }.joinToString("\n\n")
            val predPrompt   = buildPredictionPrompt(cpReading, predContext)
            val resPred = runCatching { gemma.generateRaw(predPrompt) }.getOrElse { fallbackResult() }
            resultsPred.add(resPred)
            predictions.add(parsePrediction(resPred.rawOutput, nextHasFault))
        }

        // ── Task 3 — Cumulative maintenance report ───────────────────────────
        onProgress(numCPs * 3, total, "── Task 3: Maintenance report ──")
        val gt = GroundTruth(
            totalAnomalies = dataset.stats.anomalyCount,
            maxTemp        = dataset.stats.maxTemp,
            minTemp        = dataset.stats.minTemp,
            anomalyMinutes = dataset.stats.anomalyMinutes,
        )

        val reportPromptA = buildReportPrompt(context = null)
        logBlock("REPORT A prompt (stateless)", reportPromptA)
        val reportRawA = runCatching { gemma.generateRaw(reportPromptA) }.getOrNull()?.rawOutput ?: ""
        logBlock("REPORT A raw", reportRawA)

        val synthContext  = storage.buildSynthesisContext()
        val reportPromptB = buildReportPrompt(synthContext)
        logBlock("REPORT B context", synthContext)
        logBlock("REPORT B prompt (augmented)", reportPromptB)
        val reportRawB = runCatching { gemma.generateRaw(reportPromptB) }.getOrNull()?.rawOutput ?: ""
        logBlock("REPORT B raw", reportRawB)

        gemma.close()

        // ── Assemble & score ─────────────────────────────────────────────────
        val checkpoints = (0 until numCPs).map { i ->
            CheckpointResult(
                cpIndex           = i,
                minute            = dataset.readings[dataset.checkpointIndices[i]].minute,
                windowHasAnomaly  = dataset.windowHasAnomaly(i),
                stateless         = statelessDecisions[i],
                augmented         = augmentedDecisions[i],
                prediction        = predictions[i],
                backendLatencyUs  = backendLatencies[i],
                inferenceMsA      = resultsA[i].inferenceMs,
                inferenceMsB      = resultsB[i].inferenceMs,
                promptTokensA     = resultsA[i].promptTokens,
                promptTokensB     = resultsB[i].promptTokens,
                promptTokensPred  = resultsPred.getOrNull(i)?.promptTokens ?: 0,
            )
        }

        val reportStateless = scoreReport(reportRawA, gt)
        val reportAugmented = scoreReport(reportRawB, gt)

        // Legacy synthesis block (for cross-run comparability)
        val synthesis = mapOf(
            "stateless_raw"   to reportRawA,
            "augmented_raw"   to reportRawB,
            "stateless_score" to mapOf(
                "total" to reportStateless.consistencyScore,
                "fault_count_correct" to reportStateless.faultCountCorrect,
                "max_temp_correct" to reportStateless.maxTempCorrect,
            ),
            "augmented_score" to mapOf(
                "total" to reportAugmented.consistencyScore,
                "fault_count_correct" to reportAugmented.faultCountCorrect,
                "max_temp_correct" to reportAugmented.maxTempCorrect,
            ),
        )

        val batteryAfter = snapshotBattery()
        val results = ExperimentResults(
            device           = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            model            = modelPath.substringAfterLast("/"),
            platform         = "Android",
            checkpoints      = checkpoints,
            reportStateless  = reportStateless,
            reportAugmented  = reportAugmented,
            synthesis        = synthesis,
            groundTruth      = gt,
            batteryBefore    = batteryBefore,
            batteryAfter     = batteryAfter,
        )

        saveResults(results)
        printSummary(results)
        return results
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Prompt builders
    // ─────────────────────────────────────────────────────────────────────────

    private fun buildDetectionPrompt(
        reading: SensorReading,
        window: List<SensorReading>,
        context: String?,
    ): String {
        val wMax = window.maxOfOrNull { it.tempC } ?: reading.tempC
        val wMin = window.minOfOrNull { it.tempC } ?: reading.tempC
        val hotFault  = wMax > FAULT_HIGH
        val coldFault = wMin < FAULT_LOW
        val faultLine = when {
            hotFault && coldFault ->
                "⚠ FAULT: max ${f1(wMax)}°C (>$FAULT_HIGH) AND min ${f1(wMin)}°C (<$FAULT_LOW)"
            hotFault  -> "⚠ FAULT: window max ${f1(wMax)}°C exceeds hot threshold ($FAULT_HIGH°C)"
            coldFault -> "⚠ FAULT: window min ${f1(wMin)}°C below cold threshold ($FAULT_LOW°C)"
            else      -> "OK: window ${f1(wMin)}–${f1(wMax)}°C within normal limits"
        }
        val directive = if (context.isNullOrEmpty()) "No memory — classify from readings only."
                        else "Memory context above — use it to calibrate severity."
        val question = """
            t=${reading.minute}min | current: ${f1(reading.tempC)}°C | humidity:${f0(reading.humidity)}%
            $faultLine
            $directive
            Classify: {"anomaly":"yes" or "no","severity":"none" or "low" or "high","trend":"stable" or "increasing" or "decreasing"}
        """.trimIndent()
        return wrapWithContext(context, question)
    }

    private fun buildPredictionPrompt(reading: SensorReading, context: String?): String {
        val directive = if (context.isNullOrEmpty()) "No memory available."
                        else "Use memory context above to recognize recurring fault patterns."
        val question = """
            t=${reading.minute}min | current: ${f1(reading.tempC)}°C
            $directive
            Predict the risk of a fault event in the NEXT 20 minutes for this sensor.
            Reply: {"risk_pct":<0-100>,"risk_level":"low" or "medium" or "high","reasoning":"<one sentence>"}
        """.trimIndent()
        return wrapWithContext(context, question)
    }

    private fun buildReportPrompt(context: String?): String {
        val directive = if (context.isNullOrEmpty())
            "No session data available — answer from inference only."
        else
            "Full session data is provided above."
        val question = """
            You have completed a ${if (context.isNullOrEmpty()) "monitoring" else "400-minute"} session.
            $directive
            Provide a maintenance report:
            1. Total fault events detected
            2. Maximum temperature recorded
            3. Minimum temperature recorded (cold-fault / dropout?)
            4. Fault pattern types observed (spike / drift / dropout / oscillation / precursor)
            5. Overall sensor health: healthy / degraded / critical
            Reply: {"total_faults":<int>,"max_temp":<float>,"min_temp":<float>,"patterns":"<comma-separated>","health":"healthy" or "degraded" or "critical","summary":"<one sentence>"}
        """.trimIndent()
        return wrapWithContext(context, question)
    }

    private fun wrapWithContext(context: String?, question: String): String = buildString {
        if (!context.isNullOrEmpty()) {
            append(context)
            append("\n\n")
        }
        append(question)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Parsing
    // ─────────────────────────────────────────────────────────────────────────

    private fun parseAnomalyDecision(raw: String): AnomalyDecision {
        val anomaly  = extractJsonString(raw, "anomaly") ?: "no"
        val severity = extractJsonString(raw, "severity") ?: "none"
        val trend    = extractJsonString(raw, "trend") ?: "stable"
        return AnomalyDecision(
            detected = anomaly.lowercase() == "yes",
            severity = severity.lowercase(),
            trend    = trend.lowercase(),
            rawJson  = raw,
        )
    }

    private fun parsePrediction(raw: String, nextWindowHasFault: Boolean): RiskPrediction {
        val riskPct   = extractJsonInt(raw, "risk_pct") ?: 50
        val riskLevel = extractJsonString(raw, "risk_level") ?: "medium"
        val predicted = riskPct >= 50
        return RiskPrediction(
            riskPct              = riskPct.coerceIn(0, 100),
            riskLevel            = riskLevel.lowercase(),
            rawJson              = raw,
            nextWindowHasFault   = nextWindowHasFault,
            predictionCorrect    = predicted == nextWindowHasFault,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scoring
    // ─────────────────────────────────────────────────────────────────────────

    private fun scoreReport(raw: String, gt: GroundTruth): ReportScore {
        val count  = extractJsonInt(raw, "total_faults")
        val maxT   = extractJsonDouble(raw, "max_temp")
        val minT   = extractJsonDouble(raw, "min_temp")
        val lower  = raw.lowercase()

        val countOk = count?.let { kotlin.math.abs(it - gt.totalAnomalies) <= 3 } ?: false
        val maxOk   = maxT?.let { kotlin.math.abs(it - gt.maxTemp) <= 2.0 } ?: false
        val minOk   = minT?.let { it < 5.0 } ?: false   // any value < 5 shows dropout awareness

        // Count how many of the 5 fault pattern keywords appear in the report
        val patternKeywords = listOf("spike", "drift", "dropout", "oscillation", "precursor")
        val patternsFound   = patternKeywords.count { lower.contains(it) }

        return ReportScore(
            faultCountCorrect = countOk,
            maxTempCorrect    = maxOk,
            minTempCorrect    = minOk,
            patternsIdentified = patternsFound,
            consistencyScore  = listOf(countOk, maxOk, minOk).count { it },
            raw               = raw,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Logging / persistence
    // ─────────────────────────────────────────────────────────────────────────

    private fun logBlock(title: String, body: String) {
        val banner = "────── $title ──────"
        Log.i(TAG, banner)
        body.lineSequence().forEach { Log.i(TAG, it) }
        Log.i(TAG, "─".repeat(banner.length))
        onProgress(-2, -2, "\n$banner\n$body\n")
    }

    private fun printSummary(r: ExperimentResults) {
        val tp = r.checkpoints.count { it.windowHasAnomaly }
        val tn = r.checkpoints.size - tp

        // Task 1 — detection
        val recallA   = r.checkpoints.count { it.windowHasAnomaly && it.stateless.detected  }.toDouble() / tp.coerceAtLeast(1)
        val recallB   = r.checkpoints.count { it.windowHasAnomaly && it.augmented.detected  }.toDouble() / tp.coerceAtLeast(1)
        val fprA      = r.checkpoints.count { !it.windowHasAnomaly && it.stateless.detected }.toDouble() / tn.coerceAtLeast(1)
        val fprB      = r.checkpoints.count { !it.windowHasAnomaly && it.augmented.detected }.toDouble() / tn.coerceAtLeast(1)

        // Task 2 — prediction
        val predResults = r.checkpoints.mapNotNull { it.prediction }
        val predAcc = if (predResults.isEmpty()) 0.0
                      else predResults.count { it.predictionCorrect }.toDouble() / predResults.size
        val predRecall = predResults.count { it.nextWindowHasFault && it.predictionCorrect }.toDouble() /
                         predResults.count { it.nextWindowHasFault }.coerceAtLeast(1)

        // Task 3 — report
        val repA = r.reportStateless
        val repB = r.reportAugmented

        val avgLat  = r.checkpoints.map { it.backendLatencyUs }.average()
        val avgTokA = r.checkpoints.map { it.promptTokensA }.average()
        val avgTokB = r.checkpoints.map { it.promptTokensB }.average()
        val avgTokP = r.checkpoints.map { it.promptTokensPred }.average()

        val summary = """
            ══════════════════════════════════════════════════════
              EXPERIMENT v2 COMPLETE — ${r.device}
            ══════════════════════════════════════════════════════
            Model   : ${r.model}   Backend: $backendName
            Dataset : 400 readings, ${r.checkpoints.size} checkpoints, $tp fault windows

            Task 1 — Fault Detection:
              Recall    A(stateless)=${pct(recallA)}  B(augmented)=${pct(recallB)}  Δ=${pct(recallB-recallA)}
              FPR       A=${pct(fprA)}  B=${pct(fprB)}

            Task 2 — Risk Prediction (augmented only):
              Accuracy  ${pct(predAcc)}  |  Fault-recall ${pct(predRecall)}

            Task 3 — Maintenance Report:
              Stateless : count_ok=${repA.faultCountCorrect}  max_ok=${repA.maxTempCorrect}  min_ok=${repA.minTempCorrect}  patterns=${repA.patternsIdentified}/5  score=${repA.consistencyScore}/3
              Augmented : count_ok=${repB.faultCountCorrect}  max_ok=${repB.maxTempCorrect}  min_ok=${repB.minTempCorrect}  patterns=${repB.patternsIdentified}/5  score=${repB.consistencyScore}/3

            Avg tokens: A=${String.format("%.0f", avgTokA)}  B=${String.format("%.0f", avgTokB)}  pred=${String.format("%.0f", avgTokP)}
            Retrieval latency: ${String.format("%.1f", avgLat)} µs avg
        """.trimIndent()

        Log.i(TAG, summary)
        onProgress(-1, -1, "\n$summary")
    }

    private fun pct(v: Double) = String.format("%+.0f%%", v * 100)

    private fun saveResults(results: ExperimentResults) {
        val dict = serialise(results)
        val json = gson.toJson(dict)
        val ts   = System.currentTimeMillis()
        val fileName = "experiment_android_${Build.MODEL.replace(" ", "_")}_$ts.json"
        val file = try {
            val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            docs.mkdirs()
            File(docs, fileName)
        } catch (_: Exception) { File(context.filesDir, fileName) }
        file.writeText(json)
        onProgress(-1, -1, "Results saved: ${file.absolutePath}")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JSON serialisation
    // ─────────────────────────────────────────────────────────────────────────

    private fun serialise(r: ExperimentResults): Map<String, Any> {
        val out = linkedMapOf<String, Any>()
        out["type"]       = "full_experiment_v2"
        out["device"]     = r.device
        out["model"]      = r.model
        out["backend"]    = backendName
        out["platform"]   = r.platform
        out["timestamp"]  = java.time.Instant.now().toString()
        out["device_info"] = collectDeviceInfo()
        r.batteryBefore?.let { out["battery_before"] = it }
        r.batteryAfter?.let  { out["battery_after"]  = it }

        out["ground_truth"] = mapOf(
            "total_anomalies" to r.groundTruth.totalAnomalies,
            "max_temp"        to r.groundTruth.maxTemp,
            "min_temp"        to r.groundTruth.minTemp,
            "anomaly_minutes" to r.groundTruth.anomalyMinutes,
        )

        out["checkpoints"] = r.checkpoints.map { cp ->
            mapOf(
                "cp_index"           to cp.cpIndex,
                "minute"             to cp.minute,
                "window_has_anomaly" to cp.windowHasAnomaly,
                "stateless" to mapOf(
                    "detected" to cp.stateless.detected,
                    "severity" to cp.stateless.severity,
                    "trend"    to cp.stateless.trend,
                    "raw_json" to cp.stateless.rawJson,
                ),
                "augmented" to mapOf(
                    "detected" to cp.augmented.detected,
                    "severity" to cp.augmented.severity,
                    "trend"    to cp.augmented.trend,
                    "raw_json" to cp.augmented.rawJson,
                ),
                "prediction" to cp.prediction?.let { p -> mapOf(
                    "risk_pct"            to p.riskPct,
                    "risk_level"          to p.riskLevel,
                    "next_window_fault"   to p.nextWindowHasFault,
                    "prediction_correct"  to p.predictionCorrect,
                    "raw_json"            to p.rawJson,
                )},
                "backend_latency_us" to cp.backendLatencyUs,
                "inference_ms_a"     to cp.inferenceMsA,
                "inference_ms_b"     to cp.inferenceMsB,
                "prompt_tokens_a"    to cp.promptTokensA,
                "prompt_tokens_b"    to cp.promptTokensB,
                "prompt_tokens_pred" to cp.promptTokensPred,
            )
        }

        out["report"] = mapOf(
            "stateless" to mapOf(
                "raw"                to r.reportStateless.raw,
                "fault_count_correct" to r.reportStateless.faultCountCorrect,
                "max_temp_correct"   to r.reportStateless.maxTempCorrect,
                "min_temp_correct"   to r.reportStateless.minTempCorrect,
                "patterns_identified" to r.reportStateless.patternsIdentified,
                "consistency_score"  to r.reportStateless.consistencyScore,
            ),
            "augmented" to mapOf(
                "raw"                to r.reportAugmented.raw,
                "fault_count_correct" to r.reportAugmented.faultCountCorrect,
                "max_temp_correct"   to r.reportAugmented.maxTempCorrect,
                "min_temp_correct"   to r.reportAugmented.minTempCorrect,
                "patterns_identified" to r.reportAugmented.patternsIdentified,
                "consistency_score"  to r.reportAugmented.consistencyScore,
            ),
        )

        out["synthesis"] = r.synthesis

        val tp = r.checkpoints.filter { it.windowHasAnomaly }
        val tn = r.checkpoints.filter { !it.windowHasAnomaly }
        val recA = tp.count { it.stateless.detected }.toDouble() / tp.size.coerceAtLeast(1)
        val recB = tp.count { it.augmented.detected }.toDouble() / tp.size.coerceAtLeast(1)
        val fprA = tn.count { it.stateless.detected }.toDouble() / tn.size.coerceAtLeast(1)
        val fprB = tn.count { it.augmented.detected }.toDouble() / tn.size.coerceAtLeast(1)
        val preds = r.checkpoints.mapNotNull { it.prediction }
        val predAcc = if (preds.isEmpty()) 0.0 else preds.count { it.predictionCorrect }.toDouble() / preds.size
        val predRec = preds.count { it.nextWindowHasFault && it.predictionCorrect }.toDouble() /
                      preds.count { it.nextWindowHasFault }.coerceAtLeast(1)

        out["metrics"] = mapOf(
            // Task 1
            "recall_stateless"          to recA,
            "recall_augmented"          to recB,
            "recall_delta"              to (recB - recA),
            "fpr_stateless"             to fprA,
            "fpr_augmented"             to fprB,
            // Task 2
            "prediction_accuracy"       to predAcc,
            "prediction_fault_recall"   to predRec,
            // Task 3
            "report_score_stateless"    to r.reportStateless.consistencyScore,
            "report_score_augmented"    to r.reportAugmented.consistencyScore,
            "report_patterns_stateless" to r.reportStateless.patternsIdentified,
            "report_patterns_augmented" to r.reportAugmented.patternsIdentified,
            // Tokens
            "avg_prompt_tokens_a"       to r.checkpoints.map { it.promptTokensA }.average(),
            "avg_prompt_tokens_b"       to r.checkpoints.map { it.promptTokensB }.average(),
            "avg_prompt_tokens_pred"    to r.checkpoints.map { it.promptTokensPred }.average(),
            "avg_context_tokens"        to (r.checkpoints.map { it.promptTokensB }.average()
                                           - r.checkpoints.map { it.promptTokensA }.average()),
            // Latency
            "backend_avg_latency_us"    to r.checkpoints.map { it.backendLatencyUs }.average(),
            "avg_inference_ms_a"        to r.checkpoints.map { it.inferenceMsA }.average(),
            "avg_inference_ms_b"        to r.checkpoints.map { it.inferenceMsB }.average(),
            "true_positive_cps"         to tp.size,
            "true_negative_cps"         to tn.size,
        )
        return out
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JSON field extractors
    // ─────────────────────────────────────────────────────────────────────────

    private fun extractJsonString(s: String, key: String): String? =
        Regex(""""$key"\s*:\s*"([^"]+)"""").find(s)?.groupValues?.getOrNull(1)

    private fun extractJsonInt(s: String, key: String): Int? =
        Regex(""""$key"\s*:\s*([0-9]+)""").find(s)?.groupValues?.getOrNull(1)?.toIntOrNull()

    private fun extractJsonDouble(s: String, key: String): Double? =
        Regex(""""$key"\s*:\s*([0-9]+(?:\.[0-9]+)?)""").find(s)?.groupValues?.getOrNull(1)?.toDoubleOrNull()

    // ─────────────────────────────────────────────────────────────────────────
    // Device / battery helpers
    // ─────────────────────────────────────────────────────────────────────────

    private fun fallbackResult() = GemmaInference.InferenceResult(
        rawOutput    = """{"anomaly":"no","severity":"none","trend":"stable"}""",
        parsedAnswer = null,
        promptTokens = 0,
        inferenceMs  = 0,
    )

    private fun f1(v: Double) = String.format("%.1f", v)
    private fun f0(v: Double) = String.format("%.0f", v)

    private fun collectDeviceInfo(): Map<String, Any?> {
        val memTotalKb = try {
            java.io.File("/proc/meminfo").readLines()
                .firstOrNull { it.startsWith("MemTotal") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()
        } catch (_: Exception) { null }

        val cpuFreqsKhz = (0 until Runtime.getRuntime().availableProcessors()).map { idx ->
            try {
                java.io.File("/sys/devices/system/cpu/cpu$idx/cpufreq/cpuinfo_max_freq")
                    .readText().trim().toLongOrNull()
            } catch (_: Exception) { null }
        }
        val internalStat = runCatching { StatFs(context.filesDir.absolutePath) }.getOrNull()
        return linkedMapOf(
            "model"               to Build.MODEL,
            "manufacturer"        to Build.MANUFACTURER,
            "cpu_cores"           to Runtime.getRuntime().availableProcessors(),
            "cpu_max_freqs_khz"   to cpuFreqsKhz,
            "ram_total_kb"        to memTotalKb,
            "storage_free_bytes"  to internalStat?.let { it.blockSizeLong * it.availableBlocksLong },
            "android_version"     to Build.VERSION.RELEASE,
            "sdk_int"             to Build.VERSION.SDK_INT,
            "abi"                 to Build.SUPPORTED_ABIS.firstOrNull(),
            "platform"            to "Android",
        )
    }

    private fun snapshotBattery(): Map<String, Any?> {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level  = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale  = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val pct    = if (level >= 0 && scale > 0) level.toDouble() / scale.toDouble() else -1.0
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val state  = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING    -> "charging"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "unplugged"
            BatteryManager.BATTERY_STATUS_FULL        -> "full"
            else                                      -> "unknown"
        }
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        return linkedMapOf(
            "level"              to pct,
            "state"              to state,
            "temperature_c"      to intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
                                          ?.takeIf { it != Int.MIN_VALUE }?.let { it / 10.0 },
            "voltage_mv"         to intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)?.takeIf { it >= 0 },
            "charge_counter_uah" to bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
                                       ?.takeIf { it != Int.MIN_VALUE && it != 0 },
            "timestamp"          to java.time.Instant.now().toString(),
        )
    }

    companion object {
        private const val TAG        = "DazzleExperiment"
        private const val FAULT_HIGH = 28.0
        private const val FAULT_LOW  = 5.0

        // No SYSTEM_INSTRUCTION here — the agent persona and domain threshold
        // live in GemmaInference.SYSTEM_PROMPT (the LiteRT systemInstruction
        // turn). Putting text here would land in the USER turn and conflict.
    }
}
