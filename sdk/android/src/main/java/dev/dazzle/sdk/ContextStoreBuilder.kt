// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

/**
 * Fluent builder for a [ContextStore] bound to a Dazzle client namespace.
 *
 * Obtain from [Dazzle.contextStore]; call `encode` / `decode` (required)
 * plus any of the optional index hooks, then the store is constructed
 * automatically when the builder lambda returns.
 *
 * ```kotlin
 * val chat = dazzle.contextStore<ChatMessage>("chat:42") {
 *     encode { m -> mapOf("role" to m.role.name, "text" to m.text) }
 *     decode { f -> ChatMessage(Role.valueOf(f["role"]!!), f["text"]!!) }
 *
 *     semanticSearch(dim = 384) { m -> embedder.embed(m.text) }
 *     timeRange { m -> m.timestamp }
 *     tags      { m -> setOf("role:${m.role.name.lowercase()}") }
 *
 *     execution = ExecutionPolicy.parallel  // per-store override; optional
 * }
 * ```
 */
class ContextStoreBuilder<T> internal constructor(
    private val dazzle: Dazzle,
    private val name: String,
) {
    private var encoder: ((T) -> Map<String, String>)? = null
    private var decoder: ((Map<String, String>) -> T)? = null
    private var embedder: ((T) -> FloatArray)? = null
    private var embeddingDim: Int? = null
    private var embedAlgorithm: VectorIndex.Algorithm = VectorIndex.Algorithm.HNSW
    private var embedMetric: VectorIndex.Metric = VectorIndex.Metric.COSINE
    private var timeExtractor: ((T) -> Long)? = null
    private var tagsExtractor: ((T) -> Set<String>)? = null

    /** Per-store execution policy. When null, inherits from `DazzleConfig.execution`. */
    var execution: ExecutionPolicy? = null

    /** Serialize a value into the flat `String → String` shape stored in Valkey.
     *  Every field the caller wants to retrieve later must appear here. */
    fun encode(fn: (T) -> Map<String, String>) { encoder = fn }

    /** Reconstruct a value from its stored fields. Receives the map as written
     *  by [encode] (minus any SDK-reserved fields like `_embedding`). */
    fun decode(fn: (Map<String, String>) -> T) { decoder = fn }

    /**
     * Declare semantic-search support for this store. When set, [put] computes
     * the embedding synchronously and stores it alongside the record, and
     * [ContextStore.semanticSearch] returns hits; when absent, the search
     * methods return empty.
     *
     * @param dim       vector dimensionality. Must match the embedder output.
     * @param algorithm index algorithm (HNSW default; FLAT for small / exact sets).
     * @param metric    distance metric (COSINE default; L2 / IP also supported).
     * @param embed     how to compute the vector from an instance of [T].
     */
    @JvmOverloads
    fun semanticSearch(
        dim: Int,
        algorithm: VectorIndex.Algorithm = VectorIndex.Algorithm.HNSW,
        metric: VectorIndex.Metric = VectorIndex.Metric.COSINE,
        embed: (T) -> FloatArray,
    ) {
        require(dim > 0) { "embedding dim must be positive, got $dim" }
        embeddingDim = dim
        embedAlgorithm = algorithm
        embedMetric = metric
        embedder = embed
    }

    /** Declare a timestamp extractor — enables [ContextStore.byTimeRange].
     *  Timestamps are stored as doubles in a SortedSet; any epoch-based
     *  representation works (millis, seconds, microseconds). */
    fun timeRange(extract: (T) -> Long) { timeExtractor = extract }

    /** Declare a tag extractor — enables [ContextStore.byTag] / [ContextStore.byTags].
     *  Each tag becomes a Valkey Set; SINTER does the intersection natively. */
    fun tags(extract: (T) -> Set<String>) { tagsExtractor = extract }

    internal fun build(): ContextStore<T> {
        val enc = requireNotNull(encoder) {
            "ContextStore '$name' requires encode { ... } — cannot serialize values without it"
        }
        val dec = requireNotNull(decoder) {
            "ContextStore '$name' requires decode { ... } — cannot deserialize values without it"
        }
        return DazzleContextStore(
            dazzle = dazzle,
            name = name,
            encoder = enc,
            decoder = dec,
            embedder = embedder,
            embeddingDim = embeddingDim,
            embedAlgorithm = embedAlgorithm,
            embedMetric = embedMetric,
            timeExtractor = timeExtractor,
            tagsExtractor = tagsExtractor,
            execution = execution,
        )
    }
}

/**
 * Build a typed [ContextStore] on top of this Dazzle client.
 *
 * The store uses a dedicated Valkey key namespace (`cs:<name>:…`) so
 * multiple stores can coexist in the same database without collision.
 *
 * @param name logical identifier — e.g. `"chat:42"`, `"sensors:alpha"`.
 *             Must be stable across app restarts for persistence to work.
 */
fun <T> Dazzle.contextStore(
    name: String,
    build: ContextStoreBuilder<T>.() -> Unit,
): ContextStore<T> = ContextStoreBuilder<T>(this, name).apply(build).build()
