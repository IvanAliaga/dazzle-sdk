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

import dev.dazzle.sdk.ServerInfo

/**
 * Extract the Valkey memory accounting fields exposed by `INFO memory`.
 * Only known numeric keys are returned (no raw "human" strings or peak
 * timestamps), so the result is safe to serialize as `Map<String, Long>`.
 *
 * The whole point is to publish the *full* breakdown (used_memory,
 * used_memory_dataset, used_memory_overhead, used_memory_rss,
 * used_memory_peak) instead of collapsing to one number — the Android
 * and iOS builds of Valkey may include different fields, and we want
 * the JSON consumer to see exactly what each platform reported.
 */
fun valkeyMemoryBreakdown(server: ServerInfo): Map<String, Long> {
    val mem = server.rawSections["Memory"] ?: return emptyMap()
    val keys = listOf(
        "used_memory",
        "used_memory_dataset",
        "used_memory_overhead",
        "used_memory_rss",
        "used_memory_peak",
    )
    val out = LinkedHashMap<String, Long>()
    for (k in keys) {
        val v = mem[k]?.toLongOrNull() ?: continue
        out[k] = v
    }
    return out
}

/**
 * Pluggable storage backend for the Sequential Monitoring Agent experiment.
 *
 * Every implementation stores the same sensor data (200 readings,
 * running aggregates, anomaly indices, agent checkpoint decisions) and
 * builds the same context blocks that get injected into the Gemma prompt.
 * The experiment pipeline ([ExperimentPipelineIoT]) accepts a backend name
 * and instantiates the corresponding implementation at run time, so the
 * only variable across runs is the storage engine — model, dataset, and
 * prompt formatting are identical.
 *
 * Implementations shipped in this repo:
 *   - [ValkeyContextManager]  — embedded Valkey 8, type-safe primitive API
 *   - [SqliteContextManager]  — Android/iOS native SQLite, raw SQL
 *   - (planned) RocksDbContextManager — RocksDB LSM-tree KV
 *   - (planned) ObjectBoxContextManager — ObjectBox object store + vector
 */
interface StorageBackend {

    /** Human-readable name used in logs and the exported JSON. */
    val backendName: String

    /** Delete all stored state (called at the start of each experiment run). */
    fun flush()

    /** Ingest one sensor reading into the store. */
    fun ingest(reading: SensorReading)

    /**
     * Build a natural-language context block for prompt injection at
     * a given checkpoint. The exact text must be identical across
     * backends so the model receives the same prompt — any deviation
     * is a confounding variable.
     */
    fun buildContextBlock(currentMinute: Int, windowMinutes: Int = 20): String

    /** Full-session context for the CP10 synthesis step. */
    fun buildSynthesisContext(): String

    /** Persist the agent's anomaly-detection decision for a checkpoint. */
    fun storeCheckpointDecision(
        index: Int,
        minute: Int,
        anomalyDetected: Boolean,
        severity: String,
        trend: String,
    )

    /**
     * Prediction context for Task 2 — pre-fault signature matching.
     * Returns an empty string for backends without a precursor index.
     */
    fun buildPredictionContext(currentMinute: Int): String = ""

    /**
     * Deterministic rule-based fault risk score for Task 2.
     *
     * Complementary to LLM-based prediction: any LLM (Gemma 4, Phi, SmolLM,
     * future minified models) struggles with binary calibration of rare
     * events. This engine computes a calibrated probability from the same
     * features already indexed (fault history, window stats, precursor KNN),
     * using universal signals that do not depend on model choice.
     *
     * Returns null for backends without enough state to compute (e.g. plain
     * storage backends without vector indices).
     */
    fun computeRuleBasedRisk(currentMinute: Int): FaultRiskAssessment? = null

    /** Measure round-trip time of [buildContextBlock] in microseconds. */
    fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        return (System.nanoTime() - start) / 1_000.0
    }

    /**
     * Feed the ground-truth outcome for the most recent [computeRuleBasedRisk]
     * call so an online-learning backend (TFI) can update its Bayesian
     * posteriors. No-op on backends that do not maintain per-signal
     * confidence tables.
     */
    fun observeActualFault(actualFault: Boolean) { /* no-op */ }

    /**
     * Bytes currently consumed by this backend's data — its own,
     * not the surrounding process. Returns -1 if not measurable.
     *
     * Each implementation reports the natural metric for its medium
     * (in-memory engine → live dataset bytes; disk-backed engine →
     * file/dir size on disk; pure-collection backend → estimate from
     * the structures themselves). The caller takes a before/after
     * delta to attribute payload growth to the backend, free of the
     * GC noise that contaminates process-wide PSS at small N.
     *
     * The companion field [backendSizeMethod] documents how the
     * number was obtained so the JSON readers can interpret it.
     */
    fun backendSizeBytes(): Long = -1L

    /** How [backendSizeBytes] was computed (e.g. "valkey:used_memory_dataset",
     *  "sqlite:file_size", "filesystem:dir_size", "inmemory:estimate"). */
    val backendSizeMethod: String get() = "unknown"

    /**
     * Optional fine-grained breakdown for backends whose [backendSizeBytes]
     * number is one of several published memory stats (Valkey reports
     * `used_memory`, `used_memory_dataset`, `used_memory_overhead`,
     * `used_memory_rss` simultaneously). Returning the full map lets the
     * JSON consumer choose the right comparison field without re-running.
     * Returns null for backends with a single number.
     */
    fun backendSizeBreakdown(): Map<String, Long>? = null
}

/**
 * Deterministic rule-based assessment of upcoming-window fault probability.
 *
 * The probability is computed from universal features of any time-series
 * fault-monitoring process — deliberately model-agnostic so the signal
 * remains valid when the LLM is swapped (Gemma 4 → Phi → SmolLM → …).
 *
 * Fields are all informative for the final JSON report; the binary
 * `predicted` flag uses a multi-signal OR rule rather than a raw threshold
 * so each ON signal represents a concrete engineering observation.
 */
data class FaultRiskAssessment(
    /** 0.0–1.0 aggregated probability score. */
    val probability: Double,
    /** Binary prediction from the multi-signal OR rule. */
    val predicted: Boolean,
    /** Base fault rate (faults_so_far / cps_so_far). */
    val baseRate: Double,
    /** Faults observed within the last 60 readings (3 CPs). */
    val clusterDensity: Int,
    /** timeSinceLast / avgInterval. Close to 1.0 means "due" for next fault. */
    val intervalRatio: Double,
    /** % of precursor KNN matches among effective K. */
    val precursorMatchPct: Int,
    /** NORMAL | ELEVATED | COOL | FAULT_HIGH | FAULT_LOW. */
    val currentPhysicalState: String,
    /** Human-readable list of fired signals, for logging / paper ablation. */
    val firedSignals: List<String>,
)
