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
import android.util.Log
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.WipeTarget
import java.io.File

/**
 * On-device unit tests for DazzleVectorIoTValkey9Manager.
 *
 * Validates the three bugs identified in Plan 18:
 *   1. Metadata persistence: FT.HADD must not overwrite HSET metadata.
 *      Fix: setAll() AFTER vIdx.add() — mGet("minute") must return real values.
 *   2. faultPct correctness: anomalous readings ingested → KNN query near fault
 *      profile → faultPct > 0 in context block.
 *   3. MEMORY ASSESSMENT line: appears when faultPct==0 with valid entries.
 *
 * Run via:
 *   adb shell am start -n dev.dazzle.experiment.storage/.StorageActivity \
 *     --es backend dazzle-vector-test
 *
 * Each test prints PASS / FAIL to logcat tag "VecCMTest".
 * Final summary is written to /sdcard/Documents/vec_cm_test_<device>.json
 */
object DazzleVectorIoTValkey9ManagerTest {

    private const val TAG = "VecCMTest"

    data class TestResult(
        val name: String,
        val passed: Boolean,
        val detail: String,
    )

    fun run(context: Context): List<TestResult> {
        Log.i(TAG, "══ DazzleVectorIoTValkey9Manager tests ══")

        if (DazzleServer.isRunning()) DazzleServer.stop()
        DazzleServer.start(context, DazzleConfig(
            port        = 6382,
            persistence = DazzlePersistence.None,
            wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
            modules     = setOf(DazzleModule.VectorSearch),
        ))
        Thread.sleep(600)

        val results = mutableListOf<TestResult>()
        try {
            results += testMetadataPersistence()
            results += testFaultPctNonZero()
            results += testFaultPctZero()
            results += testMemoryAssessmentLine()
            results += testVelocityContext()
            results += testResolvedTagOnCascade()
            results += testWindowFaultLabelIsPhysical()
            results += testEncodingMetadataAlignment()
            results += testPrecursorWindowIndexing()
            results += testPredictionContextIsFocused()
            results += testPredictionContextStateAndCluster()
            results += testFaultRiskEngineSignals()
            results += testDatasetV3StatusCodeParsing(context)
        } finally {
            DazzleServer.stop()
        }

        val passed = results.count { it.passed }
        val total  = results.size
        Log.i(TAG, "══ Results: $passed/$total passed ══")
        for (r in results) {
            val mark = if (r.passed) "✓ PASS" else "✗ FAIL"
            Log.i(TAG, "  $mark  ${r.name}: ${r.detail}")
        }

        writeJson(context, results)
        return results
    }

    // ── Test 1: FT.HADD must not overwrite HSET metadata ────────────────────

    private fun testMetadataPersistence(): TestResult {
        val name = "metadata_persistence_after_vIdx_add"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            val reading = SensorReading(minute = 10, timestamp = "2026-01-01T00:10:00Z", tempC = 23.5, humidity = 40.0, anomalous = false)
            mgr.ingest(reading)

            // Read back via dazzle.hash().mGet — the same path used in buildKnnContext
            val dazzle = dev.dazzle.sdk.DazzleServer.client()
            val vals = dazzle.hash("svec:10").mGet("minute", "temp", "anomalous")
            val minute = vals[0]
            val temp   = vals[1]
            val anom   = vals[2]

            val ok = minute == "10" && temp == "23.5" && anom == "0"
            val detail = "minute=$minute temp=$temp anomalous=$anom"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 2: faultPct > 0 when querying near anomalous profile ───────────

    private fun testFaultPctNonZero(): TestResult {
        val name = "faultPct_nonzero_for_fault_profile"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Ingest 10 normal readings followed by 5 anomalous (high temp)
            for (m in 1..10) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 22.0, 40.0, false))
            for (m in 11..15) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 32.0, 40.0, true))

            // Build context at minute=15 — current temp is 32°C (fault profile)
            // KNN should find mostly fault readings → faultPct > 0
            val ctx = mgr.buildKnnContext(15)
            val signalLine = ctx.lines().firstOrNull { it.startsWith("Pattern signal:") } ?: ""
            val pctStr = signalLine.removePrefix("Pattern signal: ").substringBefore('%')
            val faultPct = pctStr.trim().toIntOrNull() ?: -1

            val ok = faultPct > 0
            val detail = "faultPct=$faultPct (line: \"$signalLine\")"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 3: faultPct == 0 when querying near normal profile ─────────────

    private fun testFaultPctZero(): TestResult {
        val name = "faultPct_zero_for_normal_profile"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Ingest only normal readings
            for (m in 1..20) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 22.0, 40.0, false))

            val ctx = mgr.buildKnnContext(20)
            val signalLine = ctx.lines().firstOrNull { it.startsWith("Pattern signal:") } ?: ""
            val pctStr = signalLine.removePrefix("Pattern signal: ").substringBefore('%')
            val faultPct = pctStr.trim().toIntOrNull() ?: -1

            val ok = faultPct == 0
            val detail = "faultPct=$faultPct (expected 0)"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 4: MEMORY ASSESSMENT line present when faultPct==0 ─────────────

    private fun testMemoryAssessmentLine(): TestResult {
        val name = "memory_assessment_line_when_all_normal"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            for (m in 1..20) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 22.0, 40.0, false))

            val ctx = mgr.buildKnnContext(20)
            val hasAssessment = ctx.contains("MEMORY ASSESSMENT") && ctx.contains("NORMAL")

            val detail = if (hasAssessment) "assessment line present" else "assessment line MISSING. context=\n$ctx"
            log(name, hasAssessment, detail)
            TestResult(name, hasAssessment, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 6: [RESOLVED] tag on HFE entries during HFE cascade ────────────

    private fun testResolvedTagOnCascade(): TestResult {
        val name = "resolved_tag_on_hfe_cascade"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Ingest fault window then normal readings
            for (m in 1..10) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 22.0, 40.0, false))
            for (m in 11..15) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 32.0, 40.0, true))
            for (m in 16..25) mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", 22.0, 40.0, false))

            // Simulate a fault checkpoint decision in HFE during the fault window
            mgr.storeCheckpointDecision(index = 0, minute = 13, anomalyDetected = true, severity = "high", trend = "increasing")

            // Query in the post-fault normal window — cascade conditions: faultPct=0, hfeHasRecentFault=true
            val ctx = mgr.buildKnnContext(25)
            val hasResolved = ctx.contains("[RESOLVED]")
            val hasNoRaw = !ctx.lines()
                .filter { it.contains("anomaly=yes") }
                .any { !it.contains("[RESOLVED]") }

            val ok = hasResolved && hasNoRaw
            val detail = "hasResolved=$hasResolved allFaultEntriesTagged=$hasNoRaw"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 5: velocity urgency label only when appropriate ─────────────────

    private fun testVelocityContext(): TestResult {
        val name = "velocity_urgency_label_on_rapid_rise"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Ingest readings with rising temperature — large delta per reading
            for (m in 1..5) mgr.ingest(SensorReading(m, "2026-01-01T00:0${m}:00Z", 20.0 + m * 0.5, 40.0, false))
            // Last reading causes velocity > 2°C
            mgr.ingest(SensorReading(6, "2026-01-01T00:06:00Z", 26.0, 40.0, false))

            val ctx = mgr.buildVelocityContext()
            val hasVelSection = ctx.contains("[Temperature Velocity]")
            val detail = "velocityCtx=$ctx hasSection=$hasVelSection"
            log(name, hasVelSection, detail)
            TestResult(name, hasVelSection, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 7: window_fault label must use physical criterion, not LLM ──────

    private fun testWindowFaultLabelIsPhysical(): TestResult {
        val name = "window_fault_label_uses_physical_criterion"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // ── Case A: LLM says fault, but peak never crossed threshold ──
            // Ingest window with all temps below 28°C → physical_fault=false
            for (m in 1..20) mgr.ingest(SensorReading(
                m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z",
                22.0 + (m % 4) * 0.5, 40.0, false,  // 22.0..23.5°C, all normal
            ))
            // LLM incorrectly says fault
            mgr.storeCheckpointDecision(index = 0, minute = 20, anomalyDetected = true, severity = "high", trend = "increasing")

            val dazzle = dev.dazzle.sdk.DazzleServer.client()
            val caseAFault = dazzle.hash("wvec:20").mGet("window_fault")[0]
            val caseAMaxTemp = dazzle.hash("wvec:20").mGet("max_temp")[0]

            // ── Case B: LLM says no fault, peak crossed threshold (32°C) ──
            mgr.flush()
            for (m in 1..18) mgr.ingest(SensorReading(
                m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z",
                22.0, 40.0, false,
            ))
            // Two readings above 28°C
            mgr.ingest(SensorReading(19, "2026-01-01T00:19:00Z", 32.0, 40.0, true))
            mgr.ingest(SensorReading(20, "2026-01-01T00:20:00Z", 30.0, 40.0, true))
            // LLM says not fault (wrong)
            mgr.storeCheckpointDecision(index = 0, minute = 20, anomalyDetected = false, severity = "none", trend = "stable")

            val caseBFault = dazzle.hash("wvec:20").mGet("window_fault")[0]
            val caseBMaxTemp = dazzle.hash("wvec:20").mGet("max_temp")[0]

            // Expected: A → window_fault="0" (physical truth), B → window_fault="1" (physical truth)
            val caseAOk = caseAFault == "0"
            val caseBOk = caseBFault == "1"
            val ok = caseAOk && caseBOk
            val detail = "A(peak=$caseAMaxTemp LLM=yes)→window_fault=$caseAFault (expect 0), B(peak=$caseBMaxTemp LLM=no)→window_fault=$caseBFault (expect 1)"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 8: encoding flags ⟺ window_fault metadata (low-fault case) ───

    private fun testEncodingMetadataAlignment(): TestResult {
        val name = "encoding_flags_align_with_window_fault_metadata"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Scenario: low-temp dropout window (winMin=0.8, winMax=22).
            // With the buggy encoding (lowFault uses maxTempC), this window
            // would have flags=(0,0) → match normal queries → cross-contamination.
            // With the fix (lowFault uses minTempC), flags=(0,1) → disjoint
            // subspace from normal queries → filtered out by cosine threshold.

            // Window 1 (min 1-20): low-fault — all 22°C except min=10 at 0.8°C
            for (m in 1..20) {
                val t = if (m == 10) 0.8 else 22.0
                val a = (m == 10)
                mgr.ingest(SensorReading(m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z", t, 40.0, a))
            }
            mgr.storeCheckpointDecision(index = 0, minute = 20, anomalyDetected = true, severity = "high", trend = "decreasing")

            // Verify metadata is physical-correct (winMin < 5 → window_fault=1)
            val dazzle = dev.dazzle.sdk.DazzleServer.client()
            val wvec20Fault = dazzle.hash("wvec:20").mGet("window_fault")[0]
            val metadataOk = wvec20Fault == "1"

            // Window 2 (min 21-40): fully normal — checkpoint for comparison
            for (m in 21..40) mgr.ingest(SensorReading(
                m, "2026-01-02T00:${(m-20).toString().padStart(2,'0')}:00Z",
                22.0, 40.0, false,
            ))
            mgr.storeCheckpointDecision(index = 1, minute = 40, anomalyDetected = false, severity = "none", trend = "stable")

            // Window 3 (min 41-60): fully normal — this is the query context
            for (m in 41..60) mgr.ingest(SensorReading(
                m, "2026-01-03T00:${(m-40).toString().padStart(2,'0')}:00Z",
                22.0, 40.0, false,
            ))

            val ctx = mgr.buildKnnContext(60)

            // Behavioral check: the low-fault wvec:20 must NOT appear as a close
            // match for a normal query. wvec:40 (normal, same subspace) should match.
            val excludesLowFault = !ctx.contains("t=20min")
            val includesNormal   = ctx.contains("t=40min")

            val ok = metadataOk && excludesLowFault && includesNormal
            val detail = "wvec:20 metadata=$wvec20Fault (expect 1), excludesLowFault=$excludesLowFault, includesNormal=$includesNormal"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 9: precursor uses window-level indexing (one vec per fault) ──

    private fun testPrecursorWindowIndexing(): TestResult {
        val name = "precursor_window_level_single_vec_per_fault"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Ingest 60 readings with a rising trend, then confirm fault at minute=60
            // Pre-fault window [20..40] should show rising temps (velocity > 0)
            for (m in 1..60) mgr.ingest(SensorReading(
                m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z",
                20.0 + m * 0.1, 40.0, false,
            ))
            mgr.storeCheckpointDecision(index = 0, minute = 60, anomalyDetected = true, severity = "high", trend = "increasing")

            val dazzle = dev.dazzle.sdk.DazzleServer.client()

            // Single pvec key per fault: "pvec:60" (no per-reading keys "pvec:60_m")
            val exists = dazzle.hash("pvec:60").mGet("fault_minute", "pre_velocity")
            val singleVecOk = exists[0] == "60" && exists[1] != null

            // Legacy per-reading keys must NOT exist
            val legacyPvec = dazzle.hash("pvec:60_30").mGet("pre_minute")[0]
            val noLegacyOk = legacyPvec == null

            // Query the prediction context with a similar rising window — should match
            for (m in 61..80) mgr.ingest(SensorReading(
                m, "2026-01-01T01:${(m-60).toString().padStart(2,'0')}:00Z",
                22.0 + (m-60) * 0.1, 40.0, false,
            ))
            val ctx = mgr.buildPredictionContext(80)
            val matches = ctx.contains("fault@t=60min")
            val hasCurrentBrief = ctx.contains("[Current Brief at t=80min]")
            val hasHistory      = ctx.contains("[Fault History]") && ctx.contains("Fault minutes: 60")

            val ok = singleVecOk && noLegacyOk && matches && hasCurrentBrief && hasHistory
            val detail = "singleVec=$singleVecOk noLegacy=$noLegacyOk precursorMatch=$matches currentBrief=$hasCurrentBrief history=$hasHistory"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 10: prediction context is focused, not the full detection ────

    private fun testPredictionContextIsFocused(): TestResult {
        val name = "prediction_context_focused_no_detection_noise"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Ingest 40 normal readings then confirm 2 faults to populate history
            for (m in 1..40) mgr.ingest(SensorReading(
                m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z",
                22.0 + (m % 3), 40.0, false,
            ))
            mgr.storeCheckpointDecision(index = 0, minute = 20, anomalyDetected = true, severity = "high", trend = "stable")
            mgr.storeCheckpointDecision(index = 1, minute = 40, anomalyDetected = true, severity = "high", trend = "stable")

            // Ingest more normal readings for query window
            for (m in 41..60) mgr.ingest(SensorReading(
                m, "2026-01-01T01:${(m-40).toString().padStart(2,'0')}:00Z",
                22.0, 40.0, false,
            ))

            val predCtx = mgr.buildPredictionContext(60)
            val detCtx  = mgr.buildContextBlock(60)

            // Prediction context must contain predictive signals
            val hasCurrentBrief = predCtx.contains("[Current Brief")
            val hasHistory      = predCtx.contains("[Fault History]") && predCtx.contains("Average inter-fault interval: 20")

            // And must NOT contain the full detection noise
            val noEpisodic   = !predCtx.contains("[Episodic Memory")
            val noMemAssess  = !predCtx.contains("MEMORY ASSESSMENT")
            val noHfeSection = !predCtx.contains("HFE decaying memory")

            // Detection context still has its sections (sanity check separation)
            val detectionIntact = detCtx.contains("[Sensor State]")

            val ok = hasCurrentBrief && hasHistory && noEpisodic && noMemAssess && noHfeSection && detectionIntact
            val detail = "brief=$hasCurrentBrief history=$hasHistory noEpisodic=$noEpisodic noAssess=$noMemAssess noHfe=$noHfeSection detIntact=$detectionIntact"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 11: prediction context includes physical state + cluster density

    private fun testPredictionContextStateAndCluster(): TestResult {
        val name = "prediction_context_includes_state_and_cluster"
        return try {
            val mgr = DazzleVectorIoTValkey9Manager()
            mgr.flush()

            // Scenario: 2 recent faults (cluster) + current window actively faulting.
            // Pre-fault context: minutes 1..40 normal
            for (m in 1..40) mgr.ingest(SensorReading(
                m, "2026-01-01T00:${m.toString().padStart(2,'0')}:00Z",
                22.0, 40.0, false,
            ))
            mgr.storeCheckpointDecision(index = 0, minute = 20, anomalyDetected = true, severity = "high", trend = "stable")
            mgr.storeCheckpointDecision(index = 1, minute = 40, anomalyDetected = true, severity = "high", trend = "stable")

            // Current window: include a spike so qMax > 28 (FAULT_HIGH state)
            for (m in 41..59) mgr.ingest(SensorReading(
                m, "2026-01-01T01:${(m-40).toString().padStart(2,'0')}:00Z",
                22.0, 40.0, false,
            ))
            mgr.ingest(SensorReading(60, "2026-01-01T01:20:00Z", 32.0, 40.0, true))

            val ctx = mgr.buildPredictionContext(60)

            val hasFaultHighState = ctx.contains("State: FAULT_HIGH")
            val hasRecentDensity  = ctx.contains("Faults in last 3 checkpoints")
            // 2 past faults within 60 readings (at 20 and 40, both within 60-0=60)
            val densityValueOk    = ctx.contains("Faults in last 3 checkpoints (~60 readings): 2")

            val ok = hasFaultHighState && hasRecentDensity && densityValueOk
            val detail = "faultHighState=$hasFaultHighState recentDensity=$hasRecentDensity densityValue=$densityValueOk"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 12: FaultRiskEngine signal detection (LLM-agnostic) ──────────

    private fun testFaultRiskEngineSignals(): TestResult {
        val name = "fault_risk_engine_signals_fire_correctly"
        return try {
            val results = mutableListOf<String>()

            // Case 1: cluster_dense fires as signal but does NOT trigger
            // binary prediction (clusters max out at length 2 in sparse fault
            // processes — d=3 is a LATE signal, not an early warning).
            // currentMinute=101 puts intervalRatio=0.05, well below the 0.8
            // threshold, so interval_expected does NOT mask the test.
            val c1 = FaultRiskEngine.assess(FaultRiskEngine.Input(
                currentMinute = 101, faultHistory = listOf(60, 80, 100),
                windowMin = 20.0, windowMax = 24.0, windowAvg = 22.0,
                windowVelocity = 0.1, precursorMatchPct = 0,
            ))
            if (!c1.firedSignals.contains("cluster_dense") || c1.predicted)
                results += "cluster_dense FAIL (predicted=${c1.predicted} must be false; signals=${c1.firedSignals} must contain cluster_dense)"

            // Case 2: interval_expected — timeSinceLast ≈ avgInterval → predicted
            val c2 = FaultRiskEngine.assess(FaultRiskEngine.Input(
                currentMinute = 220, faultHistory = listOf(60, 100, 140, 180),
                windowMin = 22.0, windowMax = 24.0, windowAvg = 23.0,
                windowVelocity = 0.1, precursorMatchPct = 0,
            ))
            if (!c2.predicted || !c2.firedSignals.contains("interval_expected"))
                results += "interval_expected FAIL (ratio=${c2.intervalRatio} signals=${c2.firedSignals})"

            // Case 3: overdue — timeSinceLast >> avgInterval → predicted
            val c3 = FaultRiskEngine.assess(FaultRiskEngine.Input(
                currentMinute = 300, faultHistory = listOf(60, 100, 140, 180),
                windowMin = 22.0, windowMax = 24.0, windowAvg = 23.0,
                windowVelocity = 0.1, precursorMatchPct = 0,
            ))
            if (!c3.predicted || !c3.firedSignals.contains("overdue"))
                results += "overdue FAIL (ratio=${c3.intervalRatio} signals=${c3.firedSignals})"

            // Case 4: rising_near_threshold — high velocity + elevated window → predicted
            val c4 = FaultRiskEngine.assess(FaultRiskEngine.Input(
                currentMinute = 80, faultHistory = listOf(40),
                windowMin = 22.0, windowMax = 26.5, windowAvg = 24.0,
                windowVelocity = 2.0, precursorMatchPct = 0,
            ))
            if (!c4.predicted || !c4.firedSignals.contains("rising_near_threshold"))
                results += "rising_near_threshold FAIL (vel=${c4.firedSignals})"

            // Case 5: precursor_strong — high KNN match rate → predicted
            val c5 = FaultRiskEngine.assess(FaultRiskEngine.Input(
                currentMinute = 140, faultHistory = listOf(60, 100),
                windowMin = 22.0, windowMax = 24.0, windowAvg = 23.0,
                windowVelocity = 0.1, precursorMatchPct = 75,
            ))
            if (!c5.predicted || !c5.firedSignals.contains("precursor_strong"))
                results += "precursor_strong FAIL (match=${c5.precursorMatchPct} signals=${c5.firedSignals})"

            // Case 6: NO signal — normal state, no history → NOT predicted
            val c6 = FaultRiskEngine.assess(FaultRiskEngine.Input(
                currentMinute = 39, faultHistory = emptyList(),
                windowMin = 21.0, windowMax = 24.0, windowAvg = 22.5,
                windowVelocity = 0.2, precursorMatchPct = 0,
            ))
            if (c6.predicted)
                results += "no_signal FAIL — should NOT predict (signals=${c6.firedSignals})"

            val ok = results.isEmpty()
            val detail = if (ok) "6 signal cases all correct" else "FAILED: ${results.joinToString("; ")}"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Test 13: dataset v3 status_code field parses correctly ────────────

    private fun testDatasetV3StatusCodeParsing(context: Context): TestResult {
        val name = "dataset_v3_status_code_parses_correctly"
        return try {
            val ds = DatasetLoader.load(context, "dataset_iot_valkey9.json")
            val version = ds.meta.version
            val firstNonOk = ds.readings.firstOrNull { it.statusCode != null && it.statusCode != SensorStatus.OK }
            val nonOkCount = ds.readings.count { it.statusCode != null && it.statusCode != SensorStatus.OK }

            val versionOk = version == 3
            val hasFlickers = nonOkCount >= 20
            val firstFlickerOk = firstNonOk?.statusCode != null

            val ok = versionOk && hasFlickers && firstFlickerOk
            val detail = "version=$version nonOkCount=$nonOkCount firstNonOk=min=${firstNonOk?.minute} status=${firstNonOk?.statusCode}"
            log(name, ok, detail)
            TestResult(name, ok, detail)
        } catch (e: Exception) {
            TestResult(name, false, e.message ?: "exception")
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun log(name: String, passed: Boolean, detail: String) {
        val mark = if (passed) "PASS" else "FAIL"
        Log.i(TAG, "[$mark] $name — $detail")
    }

    private fun writeJson(context: Context, results: List<TestResult>) {
        try {
            val device = android.os.Build.MODEL.replace(Regex("[^A-Za-z0-9_]"), "_")
            val dir = try {
                val d = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOCUMENTS
                )
                d.mkdirs()
                if (d.canWrite()) d else context.filesDir
            } catch (_: Exception) { context.filesDir }
            val f = File(dir, "vec_cm_test_${device}.json")
            val passed = results.count { it.passed }
            val lines = buildString {
                appendLine("{")
                appendLine("  \"device\": \"${android.os.Build.MODEL}\",")
                appendLine("  \"passed\": $passed,")
                appendLine("  \"total\": ${results.size},")
                appendLine("  \"all_passed\": ${passed == results.size},")
                appendLine("  \"tests\": [")
                results.forEachIndexed { i, r ->
                    val comma = if (i < results.size - 1) "," else ""
                    appendLine("    {\"name\": \"${r.name}\", \"passed\": ${r.passed}, \"detail\": \"${r.detail.replace("\"", "'")}\"} $comma")
                }
                appendLine("  ]")
                append("}")
            }
            f.writeText(lines)
            Log.i(TAG, "Results written to ${f.absolutePath}")
        } catch (e: Exception) {
            Log.w(TAG, "Could not write results: ${e.message}")
        }
    }
}
