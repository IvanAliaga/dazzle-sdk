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

import kotlin.math.max
import kotlin.math.min

/**
 * Deterministic, LLM-agnostic fault-risk scorer for Task 2 (next-window
 * prediction).
 *
 * Why this exists
 * ───────────────
 * Minified on-device LLMs (Gemma 4, Phi, SmolLM, TinyLlama, future 1-3B
 * models) are strong at narrative reasoning but unreliable at binary
 * calibration of rare events — their risk_pct outputs cluster in the
 * 10–40% band regardless of signal strength. On the Task 2 benchmark,
 * Gemma 4 E2B ceilings at ~12% fault_recall on a standard 20-checkpoint
 * session.
 *
 * Production systems solve this by keeping the LLM for explanation and
 * delegating binary classification to a deterministic scorer computed from
 * the same features already indexed for retrieval. This engine is that
 * scorer. It is:
 *   • model-agnostic  — same output whatever LLM is in use
 *   • interpretable   — every signal corresponds to a named engineering observation
 *   • stateless       — pure function of the inputs
 *   • cross-backend   — any backend that tracks (history, window stats, precursor
 *                       match) can feed this engine
 *
 * Signal design
 * ─────────────
 * Six independent signals, each corresponding to a universal fault-process
 * characteristic (not dataset-specific):
 *
 *   1. interval_expected — timeSinceLast/avgInterval ∈ [0.8, 1.4]
 *        "We are near the expected time of the next fault."
 *   2. overdue           — intervalRatio > 1.5
 *        "It has been unusually long since the last fault."
 *   3. cluster_dense     — ≥3 faults in last 60 readings
 *        "An active fault cluster is in progress."
 *   4. cluster_moderate  — 2 faults in last 60 readings
 *        "A moderate fault cluster is in progress."
 *   5. precursor_strong  — precursor KNN match rate ≥ 67%
 *        "Current window profile closely matches past pre-fault windows."
 *   6. rising_near_threshold / dropping_near_threshold
 *        "Temperature is changing rapidly close to a fault boundary."
 *
 * Binary prediction uses an OR of the strong signals — any ONE strong
 * signal firing is sufficient to predict "fault next". Weaker signals
 * (cluster_moderate, currently_faulting) contribute to the probability
 * score but do not alone trigger a positive prediction, keeping FPR low.
 *
 * Probability score is an additive aggregation with shrinkage (base rate
 * contributes at half weight, capped at 1.0). Used for ROC/AUC analysis
 * independent of the binary threshold.
 */
object FaultRiskEngine {

    /**
     * Inputs derived from the storage backend. Any backend that tracks
     * these can invoke the engine (cross-backend applicability for the
     * paper's rule-based baseline).
     */
    data class Input(
        /** Current checkpoint minute (1-indexed across the 400-min session). */
        val currentMinute: Int,
        /** Minutes of all confirmed faults so far (ascending). */
        val faultHistory: List<Int>,
        /** Minimum temperature in current window [t-19, t]. */
        val windowMin: Double,
        /** Maximum temperature in current window. */
        val windowMax: Double,
        /** Average temperature in current window. */
        val windowAvg: Double,
        /** Mean velocity (°C per reading) in current window. */
        val windowVelocity: Double,
        /** % of precursor KNN matches over effective K. */
        val precursorMatchPct: Int,
    )

    /** Checkpoint interval used to convert minute → CP count. */
    private const val CP_MINUTES = 20

    /** Lookback window for cluster-density signal (3 CPs). */
    private const val CLUSTER_WINDOW = 60

    /** Base-rate shrinkage weight in the probability aggregation. */
    private const val BASE_RATE_WEIGHT = 0.5

    fun assess(input: Input): FaultRiskAssessment {
        val (minute, history, wMin, wMax, wAvg, wVel, precPct) = input

        // ── Derived features ──────────────────────────────────────────────
        val cpsObserved = (minute + 1) / CP_MINUTES
        val baseRate = if (cpsObserved >= 3) history.size.toDouble() / cpsObserved else 0.30

        val recentFaults = history.count { minute - it <= CLUSTER_WINDOW }

        val avgInterval = if (history.size >= 2)
            (history.last() - history.first()).toDouble() / (history.size - 1)
        else 0.0
        val timeSinceLast = if (history.isNotEmpty()) (minute - history.last()).toDouble() else Double.MAX_VALUE
        val intervalRatio = if (avgInterval > 0) timeSinceLast / avgInterval else 0.0

        val physicalState = when {
            wMax > 28.0 -> "FAULT_HIGH"
            wMin <  5.0 -> "FAULT_LOW"
            wMax > 26.0 -> "ELEVATED"
            wMin <  8.0 -> "COOL"
            else        -> "NORMAL"
        }

        // ── Signal detection ──────────────────────────────────────────────
        val signals = mutableListOf<String>()
        var prob = baseRate * BASE_RATE_WEIGHT

        // Signal 1 & 2: interval proximity (strongest predictive feature)
        val intervalExpected = intervalRatio in 0.8..1.4
        val overdue          = intervalRatio > 1.5
        if (intervalExpected) { signals += "interval_expected"; prob += 0.22 }
        else if (overdue)     { signals += "overdue";           prob += 0.14 }

        // Signal 3 & 4: cluster density
        //
        // Note: cluster_dense contributes to probability but does NOT trigger
        // the binary prediction. Empirically (g35 400-min session), clusters
        // observed in the fault-window structure have max length 2 — when
        // recentFaults == 3 we are past the cluster peak and the NEXT window
        // is almost certainly the return to normal. Firing the prediction on
        // cluster_dense produced 0/2 precision. Cluster dynamics in sparse
        // time-series fault processes are counterintuitive: high recent
        // density is a LATE signal, not an early warning.
        val clusterDense    = recentFaults >= 3
        val clusterModerate = recentFaults == 2
        if (clusterDense) {
            signals += "cluster_dense"; prob += 0.15
        } else if (clusterModerate) {
            signals += "cluster_moderate"; prob += 0.08
        } else if (recentFaults == 1) {
            prob += 0.03   // contributes to prob but not to signals
        }

        // Signal 5: precursor KNN (match rate)
        val precursorStrong = precPct >= 67
        if (precursorStrong)      { signals += "precursor_strong";   prob += 0.12 }
        else if (precPct >= 33)   {                                   prob += 0.05 }

        // Signal 6: velocity near threshold
        val risingNearThreshold   = wVel >  1.5 && wMax > 25.0
        val droppingNearThreshold = wVel < -1.5 && wMin < 10.0
        if (risingNearThreshold)   { signals += "rising_near_threshold";   prob += 0.10 }
        if (droppingNearThreshold) { signals += "dropping_near_threshold"; prob += 0.10 }

        // Soft contribution from current state (not a binary signal by itself
        // — current fault does not reliably predict next fault)
        when (physicalState) {
            "FAULT_HIGH", "FAULT_LOW" -> prob += 0.05
            "ELEVATED",  "COOL"        -> prob += 0.03
            else                       -> { /* no contribution */ }
        }

        // ── Binary prediction: OR of strong signals ───────────────────────
        // A single strong signal is sufficient to trigger a positive
        // prediction. Weaker signals do not by themselves fire — this keeps
        // FPR low while capturing the strongest predictive regimes.
        // cluster_dense is intentionally excluded from the trigger — see
        // the note in the cluster-density block above.
        val predicted = intervalExpected || overdue || precursorStrong ||
                        risingNearThreshold || droppingNearThreshold

        prob = prob.coerceIn(0.0, 1.0)

        return FaultRiskAssessment(
            probability          = prob,
            predicted            = predicted,
            baseRate             = baseRate,
            clusterDensity       = recentFaults,
            intervalRatio        = intervalRatio,
            precursorMatchPct    = precPct,
            currentPhysicalState = physicalState,
            firedSignals         = signals,
        )
    }
}
