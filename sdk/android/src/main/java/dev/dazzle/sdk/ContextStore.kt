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

package dev.dazzle.sdk

/**
 * Generic typed record store for LLM-agent context.
 *
 * `ContextStore<T>` is domain-agnostic — it stores whatever type the caller
 * defines (`ChatMessage`, `SensorReading`, `Transaction`, …). The caller
 * supplies an `encode` / `decode` pair and the store takes care of
 * persistence, optional embedding-based retrieval, time-range queries and
 * tag filters — all composed from the underlying Valkey primitives
 * (HashKey, SortedSetKey, SetKey, VectorIndex).
 *
 * ## Typical usage
 *
 * ```kotlin
 * data class SensorReading(
 *     val sensorId: String,
 *     val temp: Double,
 *     val humidity: Double,
 *     val timestamp: Long,
 *     val anomalous: Boolean,
 * )
 *
 * val sensors = dazzle.contextStore<SensorReading>("sensors") {
 *     encode { r -> mapOf(
 *         "sensor_id" to r.sensorId,
 *         "temp"      to r.temp.toString(),
 *         "humidity"  to r.humidity.toString(),
 *         "timestamp" to r.timestamp.toString(),
 *         "anomalous" to r.anomalous.toString(),
 *     ) }
 *     decode { f -> SensorReading(
 *         sensorId  = f["sensor_id"].orEmpty(),
 *         temp      = f["temp"]?.toDoubleOrNull() ?: 0.0,
 *         humidity  = f["humidity"]?.toDoubleOrNull() ?: 0.0,
 *         timestamp = f["timestamp"]?.toLongOrNull() ?: 0L,
 *         anomalous = f["anomalous"] == "true",
 *     ) }
 *
 *     // Optional indices — declare only the ones your use-case needs
 *     semanticSearch(dim = 384) { r ->
 *         myEmbedder.embed("${r.sensorId} ${r.temp}°C ${if (r.anomalous) "anomaly" else "ok"}")
 *     }
 *     timeRange { r -> r.timestamp }
 *     tags      { r -> if (r.anomalous) setOf("anomalous") else emptySet() }
 * }
 *
 * sensors.put("r:42", reading)
 * val hits = sensors.semanticSearch("overheating station alpha", k = 5)
 * val recent = sensors.byTimeRange(start = now - 20 * 60_000, end = now)
 * ```
 *
 * ## Indices are opt-in
 *
 * Every query method returns empty / no-op if the corresponding index
 * wasn't declared at build time. This keeps the API uniform across
 * use-cases — a store with only `encode` / `decode` is still valid, just
 * with reduced query power.
 *
 * ## Thread safety
 *
 * All methods are thread-safe. Dispatch work to the caller's choice of
 * threading model (the SDK's suspend surface in future versions will use
 * `DazzleConfig.execution.dispatcher`; the synchronous surface blocks on
 * Dazzle's in-process pipe).
 */
interface ContextStore<T> : AutoCloseable {

    /** Logical name of this store — used as a Valkey key-prefix. */
    val name: String

    // ── Storage ──────────────────────────────────────────────────────────

    /** Insert or replace. If an embedder is configured, computes the vector
     *  synchronously inside this call — move to a worker thread if expensive. */
    fun put(id: String, value: T)

    /** Bulk insert. Writes are pipelined through the direct path when
     *  available, cutting FFI overhead vs N separate put() calls. */
    fun putAll(entries: Map<String, T>)

    /** Fetch. Null if the id does not exist or decoding fails. */
    fun get(id: String): T?

    /** Bulk fetch. Preserves input ordering; nulls for missing ids. */
    fun getAll(ids: List<String>): List<T?>

    /** Delete. Returns true if the id existed. */
    fun delete(id: String): Boolean

    /** Drop EVERYTHING this store owns — records + indices. */
    fun flush()

    /** Number of records currently stored. */
    fun count(): Long

    /** Iterate. Optional `match` follows Valkey SCAN pattern syntax
     *  (`*`, `?`, `[abc]`) against the id (not including the store prefix). */
    fun iterate(match: String? = null): Sequence<Pair<String, T>>

    // ── Queries — empty / no-op if the index was not declared ────────────

    /** Semantic k-NN over the embedding. Returns empty if the store has no
     *  `semanticSearch { ... }` hook configured. */
    fun semanticSearch(query: String, k: Int = 10): List<Hit<T>>

    /** Same as above but with a raw query vector. */
    fun semanticSearch(vector: FloatArray, k: Int = 10): List<Hit<T>>

    /** Records whose `timeRange { }` extractor falls in [start, end].
     *  Returns at most [limit] results, newest first. Empty if no hook. */
    fun byTimeRange(start: Long, end: Long, limit: Int = 1000): List<Pair<String, T>>

    /** Records that have [tag] in their `tags { }` set. */
    fun byTag(tag: String): Sequence<Pair<String, T>>

    /** Records that have ALL of [allOf] in their `tags { }` set. */
    fun byTags(allOf: Set<String>): Sequence<Pair<String, T>>

    /** Release any per-store resources (the underlying vector index handle,
     *  cached connections). Safe to call multiple times. The Dazzle server
     *  itself is NOT stopped — it outlives every ContextStore. */
    override fun close()
}

/** A search result: the retrieved value plus its similarity score. */
data class Hit<T>(
    val id: String,
    /** Raw distance from the vector index (lower = closer for L2 / cosine). */
    val score: Float,
    val value: T,
)
