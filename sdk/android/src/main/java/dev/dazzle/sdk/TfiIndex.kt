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

package dev.dazzle.sdk

/**
 * Type-safe wrapper around a Dazzle TFI (Temporal Fault Intelligence) key.
 * Obtain via `dazzle.tfi("key")`.
 *
 * TFI is the Dazzle-specific primitive for LLM-augmented industrial fault
 * monitoring — upstream Valkey has no equivalent. See
 * `sdk/android/src/main/cpp/tfi_module.c` for the full C-side design.
 *
 * Typical usage in an edge monitoring loop:
 *
 * ```kotlin
 * val tfi = dazzle.tfi("sensor:fault-intel")
 * tfi.init()
 *
 * // On every sensor reading:
 * tfi.ingest(minute, tempC, statusCode)
 *
 * // When the LLM detection step confirms a fault:
 * if (llmConfirmedFault) tfi.event(minute, severity = "high")
 *
 * // At each checkpoint, ask for a risk assessment:
 * val r = tfi.score(atMinute, winMin, winMax, winAvg, winVel, precursorMatchPct)
 * if (r.predicted) alarm()
 *
 * // After the ground truth is known (next CP confirms), update posteriors:
 * tfi.observe(actualFault = nextCpWasFault)
 *
 * // Explain the current confidence table (for UI / paper / debugging):
 * for (s in tfi.explain()) println("${s.name}: conf=${s.confidence}")
 * ```
 *
 * Requires [DazzleModule.TFI] in [DazzleConfig.modules]. The module is
 * compiled into `libdazzle.so` and registered at server start via
 * `--loadmodule @static:tfi`.
 */
class TfiIndex internal constructor(
    val key: String,
    private val server: DazzleServer,
) {

    /**
     * A single assessment returned by [score]. All fields are raw outputs
     * from the C engine and are safe to include verbatim in the JSON
     * results for paper tables.
     */
    data class Assessment(
        /** 0.0–1.0 aggregated probability from the additive scorer. */
        val probability: Double,
        /** Binary prediction from the multi-signal OR rule. */
        val predicted: Boolean,
        /** Running base-rate of faults so far (shrunk toward 0.30 early). */
        val baseRate: Double,
        /** Confirmed faults within the last ~60 readings. */
        val clusterDensity: Int,
        /** timeSinceLastFault / avgInterval (0.0 when insufficient history). */
        val intervalRatio: Double,
        /** Precursor KNN match percentage passed in to [score]. */
        val precursorMatchPct: Int,
        /** Current physical state label (NORMAL, ELEVATED, FAULT_HIGH, …). */
        val physicalState: String,
        /** Fired signal names, in the order the engine recognises them. */
        val firedSignals: List<String>,
    )

    /** Bayesian posterior counts + confidence for one signal. */
    data class SignalStat(
        val name: String,
        val hits: Long,
        val misses: Long,
        val confidence: Double,
    )

    // ── Lifecycle ─────────────────────────────────────────────────────────

    /** TFI.INIT — allocate per-key state. Idempotent. */
    fun init(): Boolean =
        server.commandTyped("TFI.INIT", key).isOk()

    /** TFI.RESET — clear fault history, status counts, Bayesian posteriors. */
    fun reset(): Boolean =
        server.commandTyped("TFI.RESET", key).isOk()

    /** DEL key — destroy the state entirely. */
    fun delete(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    // ── Ingest / event stream ─────────────────────────────────────────────

    /**
     * TFI.INGEST — notify TFI of a sensor reading. Updates the rolling
     * status-code buffer used by the status-flicker / out-of-range /
     * fault-reported signals. Does not alter fault history; use [event]
     * for that when the LLM detection step confirms a fault.
     */
    fun ingest(minute: Int, tempC: Double, status: String): Boolean =
        server.commandTyped("TFI.INGEST", key, minute.toString(), tempC.toString(), status).isOk()

    /**
     * TFI.EVENT — append a confirmed fault minute to the event stream.
     * Call when the LLM-augmented detection step returns anomaly=yes for
     * the current window.
     */
    fun event(minute: Int, severity: String = "high"): Boolean =
        server.commandTyped("TFI.EVENT", key, minute.toString(), severity).isOk()

    // ── Scoring ────────────────────────────────────────────────────────────

    /**
     * TFI.SCORE — compute a risk assessment. The C engine caches the fired
     * signal set internally so a subsequent [observe] can update the
     * correct Bayesian posteriors.
     *
     * @param atMinute           current checkpoint minute
     * @param winMin             min temp in the current 20-reading window
     * @param winMax             max temp in the current 20-reading window
     * @param winAvg             avg temp in the current 20-reading window
     * @param winVelocity        mean velocity (°C per reading) over the window
     * @param precursorMatchPct  % of neighbours from the precursor KNN index
     *                           (0 if no precursor layer is in use)
     */
    fun score(
        atMinute: Int,
        winMin: Double,
        winMax: Double,
        winAvg: Double,
        winVelocity: Double,
        precursorMatchPct: Int = 0,
    ): Assessment {
        val reply = server.commandTyped(
            "TFI.SCORE", key,
            atMinute.toString(),
            winMin.toString(), winMax.toString(),
            winAvg.toString(), winVelocity.toString(),
            precursorMatchPct.toString(),
        )
        val arr = reply.asArray()
        val signals = (arr.getOrNull(7)?.asBulkOrNull() ?: "")
            .split(',').filter { it.isNotEmpty() }
        return Assessment(
            probability       = arr.getOrNull(0)?.asBulkOrNull()?.toDoubleOrNull() ?: 0.0,
            predicted         = (arr.getOrNull(1)?.asLongOrNull() ?: 0L) == 1L,
            baseRate          = arr.getOrNull(2)?.asBulkOrNull()?.toDoubleOrNull() ?: 0.0,
            clusterDensity    = (arr.getOrNull(3)?.asLongOrNull() ?: 0L).toInt(),
            intervalRatio     = arr.getOrNull(4)?.asBulkOrNull()?.toDoubleOrNull() ?: 0.0,
            precursorMatchPct = (arr.getOrNull(5)?.asLongOrNull() ?: 0L).toInt(),
            physicalState     = arr.getOrNull(6)?.asBulkOrNull() ?: "NORMAL",
            firedSignals      = signals,
        )
    }

    /**
     * TFI.OBSERVE — update Bayesian posterior for every signal that fired
     * in the most recent [score] call. Call after ground truth for the
     * next window is known.
     */
    fun observe(actualFault: Boolean): Boolean =
        server.commandTyped("TFI.OBSERVE", key, if (actualFault) "1" else "0").isOk()

    // ── Introspection ──────────────────────────────────────────────────────

    /** TFI.EXPLAIN — current confidence table per signal. */
    fun explain(): List<SignalStat> {
        val arr = server.commandTyped("TFI.EXPLAIN", key).asArray()
        return arr.mapNotNull { entry ->
            val row = entry.asArray()
            if (row.size < 4) return@mapNotNull null
            SignalStat(
                name       = row[0].asBulkOrNull() ?: "",
                hits       = row[1].asLongOrNull() ?: 0L,
                misses     = row[2].asLongOrNull() ?: 0L,
                confidence = row[3].asBulkOrNull()?.toDoubleOrNull() ?: 0.0,
            )
        }
    }

    /**
     * TFI.FEATURES — raw feature vector for the current state. Useful for
     * paper ablations or feeding an external classifier.
     *
     * Order: [baseRate, clusterDensity, intervalRatio, faultCount,
     *         avgInterval, timeSinceLast, noDataCount, outOfRangeCount,
     *         faultReportedCount, atMinute]
     */
    fun features(atMinute: Int): DoubleArray {
        val arr = server.commandTyped("TFI.FEATURES", key, atMinute.toString()).asArray()
        return DoubleArray(arr.size) { i ->
            arr[i].asBulkOrNull()?.toDoubleOrNull() ?: arr[i].asLongOrNull()?.toDouble() ?: 0.0
        }
    }

    // ── Misc ──────────────────────────────────────────────────────────────

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}

// ── Response helpers ──────────────────────────────────────────────────────

private fun RespValue.isOk(): Boolean =
    (this as? RespValue.SimpleString)?.value == "OK"
