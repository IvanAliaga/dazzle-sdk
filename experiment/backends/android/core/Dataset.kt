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
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName

// ─────────────────────────────────────────────────────────────────────────────
// Dataset  —  shared sensor dataset used by both iOS and Android experiments.
//
// The dataset contains 200 one-minute sensor readings with 11 pre-labelled
// anomalies. The experiment runs 10 checkpoints (every 20 readings) on this
// sequence and asks a Gemma model to detect anomalies in two conditions:
//   A  Stateless        — Gemma sees only the current window of 20 readings
//   B  Valkey-augmented  — Gemma also sees a context block from Valkey
//
// The legacy `questions` field is no longer used since the experiment shifted
// from a Q&A benchmark to a Sequential Monitoring Agent. It is kept in the
// data class so the same dataset_iot_baseline.json continues to parse on both platforms;
// it can be dropped entirely once the legacy branch is archived.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * NAMUR NE43-style sensor status codes. Real industrial sensors ship these
 * alongside the measurement — they are a strong predictive signal that our
 * original dataset schema omitted. Pre-fault windows often contain
 * NO_DATA flickers or OUT_OF_RANGE spikes before the full fault.
 *
 *   OK              Normal operation.
 *   NO_DATA         Sensor did not respond or returned null / timeout.
 *   OUT_OF_RANGE    Value outside the sensor's physical calibration range.
 *   FAULT           Sensor is reporting a hard failure (burn-out, short).
 *   CALIB_ERROR     Sensor self-reports drift beyond calibration tolerance.
 */
enum class SensorStatus {
    OK,
    NO_DATA,
    OUT_OF_RANGE,
    FAULT,
    CALIB_ERROR;

    val isFault: Boolean get() = this != OK
}

data class SensorReading(
    val minute: Int,
    val timestamp: String,
    @field:SerializedName("temp_c") val tempC: Double,
    val humidity: Double,
    val anomalous: Boolean,
    /**
     * Sensor status at this reading. Nullable because Gson bypasses Kotlin
     * default values via reflection — a legacy dataset without status_code
     * deserialises to `null` rather than `OK`. Consumers should use
     * [effectiveStatus] to pick up the OK default for missing values.
     *
     * `@field:SerializedName` is required for the annotation to land on the
     * backing Java field; the plain `@SerializedName` on a Kotlin `val`
     * goes to the property, which Gson does not read when it reflects
     * directly over the fields.
     */
    @field:SerializedName("status_code") val statusCode: SensorStatus? = null,
) {
    /** Returns [statusCode] when present, else [SensorStatus.OK]. */
    val effectiveStatus: SensorStatus get() = statusCode ?: SensorStatus.OK
}

@Deprecated("Retired with the Q&A benchmark experiment; see branch experiment/qa-benchmark-legacy")
data class Question(
    val id: String,
    val category: String,
    @SerializedName("probe_index") val probeIndex: Int,
    val text: String,
    @SerializedName("ground_truth") val groundTruth: Any,
    @SerializedName("score_type") val scoreType: String,
    val tolerance: Double = 0.0,
)

data class DatasetMeta(
    val seed: Int,
    @SerializedName("num_readings") val numReadings: Int,
    @SerializedName("anomaly_threshold_high") val anomalyThresholdHigh: Double,
    @SerializedName("anomaly_threshold_low")  val anomalyThresholdLow: Double,
    val version: Int = 1,
    val description: String = "",
)

data class DatasetStats(
    val count: Int,
    @SerializedName("avg_temp") val avgTemp: Double,
    @SerializedName("min_temp") val minTemp: Double,
    @SerializedName("max_temp") val maxTemp: Double,
    @SerializedName("anomaly_count") val anomalyCount: Int,
    @SerializedName("anomaly_minutes") val anomalyMinutes: List<Int>,
)

data class Dataset(
    val meta: DatasetMeta,
    val stats: DatasetStats,
    val readings: List<SensorReading>,
    @Suppress("DEPRECATION")
    val questions: List<Question> = emptyList(),
) {
    /**
     * Evenly-spaced checkpoints: every 20 readings up to the end of the dataset.
     * v1 (200 readings) → 10 checkpoints at 19,39,…,199.
     * v2 (400 readings) → 20 checkpoints at 19,39,…,399.
     *
     * Must be a `get()` property (not a stored field) — Gson constructs via
     * Unsafe, skipping constructors and initializers entirely.
     */
    val checkpointIndices: List<Int>
        get() = (19 until readings.size step 20).toList()

    /** Window of readings for a given checkpoint: from (previous checkpoint + 1) to current. */
    fun window(cpIndex: Int): List<SensorReading> {
        val cps = checkpointIndices
        val endIdx   = cps[cpIndex]
        val startIdx = if (cpIndex == 0) 0 else cps[cpIndex - 1] + 1
        return readings.subList(startIdx, endIdx + 1)
    }

    /** True if the dataset contains at least one anomalous reading in the window. */
    fun windowHasAnomaly(cpIndex: Int): Boolean =
        window(cpIndex).any { it.anomalous }
}

// ── Loader ────────────────────────────────────────────────────────────────────

object DatasetLoader {
    private val gson = Gson()
    private val cache = mutableMapOf<String, Dataset>()

    /**
     * Load dataset by filename. Defaults to "dataset_iot_valkey9.json" (adds NAMUR
     * NE43 status codes to the v2 400-reading benchmark). Falls back to v2
     * if v3 is not shipped with the APK — keeps legacy builds running.
     */
    fun load(context: Context, filename: String = "dataset_iot_valkey9.json"): Dataset =
        cache.getOrPut(filename) {
            val assetName = try {
                context.assets.open(filename).use { /* probe */ }
                filename
            } catch (e: Exception) {
                android.util.Log.w("DatasetLoader",
                    "Could not open $filename (${e.javaClass.simpleName}: ${e.message}); falling back to dataset_iot_valkey8.json")
                "dataset_iot_valkey8.json"
            }
            val json = context.assets.open(assetName).bufferedReader().readText()
            val parsed = gson.fromJson(json, Dataset::class.java)
            val nonOkCount = parsed.readings.count { it.statusCode != null && it.statusCode != SensorStatus.OK }
            android.util.Log.i("DatasetLoader",
                "Loaded $assetName: ${parsed.readings.size} readings, " +
                "$nonOkCount non-OK status codes. " +
                "Sample[min=20]: statusCode=${parsed.readings.getOrNull(20)?.statusCode}")
            parsed
        }
}
