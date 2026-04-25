// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Dazzle-backed implementation of [ContextStore].
 *
 * Key namespace layout for a store named `"sensors"`:
 *
 * | Purpose | Key pattern | Primitive |
 * |---|---|---|
 * | Record (one per id) | `cs:sensors:rec:<id>` | HashKey (encode + optional `_embedding` blob) |
 * | Time index | `cs:sensors:idx:time` | SortedSetKey (score = timestamp, member = id) |
 * | Tag index | `cs:sensors:idx:tag:<tag>` | SetKey (members = ids) |
 * | Vector index | FT index `cs_sensors_vec` | valkey-search (prefix scans record hashes) |
 *
 * All indices are opt-in — when the builder doesn't declare a hook the
 * corresponding query method returns empty without touching Valkey.
 */
internal class DazzleContextStore<T>(
    private val dazzle: Dazzle,
    override val name: String,
    private val encoder: (T) -> Map<String, String>,
    private val decoder: (Map<String, String>) -> T,
    private val embedder: ((T) -> FloatArray)?,
    private val embeddingDim: Int?,
    private val embedAlgorithm: VectorIndex.Algorithm,
    private val embedMetric: VectorIndex.Metric,
    private val timeExtractor: ((T) -> Long)?,
    private val tagsExtractor: ((T) -> Set<String>)?,
    @Suppress("UNUSED_PARAMETER") execution: ExecutionPolicy?,
) : ContextStore<T> {

    /** Per-store prefix view. Every primitive obtained from [ns] has its
     *  key automatically prefixed with `cs:<name>:`. */
    private val ns: Dazzle = dazzle.namespace("cs:$name")

    /** Reserved hash field where the vector blob lives. Stripped before
     *  being handed to the caller's `decode`. */
    private val embeddingField = "_embedding"

    /** Vector index handle — null if `semanticSearch` wasn't declared. */
    private val vectorIndex: VectorIndex? = embeddingDim?.let { dim ->
        val idx = dazzle.vectorIndex(
            name = indexName,
            hashPrefix = "cs:$name:rec:",  // resolves against the un-namespaced Dazzle
            vectorField = embeddingField,
            dim = dim,
            algorithm = embedAlgorithm,
            metric = embedMetric,
        )
        idx.create()  // safe to call repeatedly
        idx
    }

    private val indexName: String
        get() = "cs_${name.replace(':', '_')}_vec"

    private val closed = AtomicBoolean(false)

    // ── Storage ───────────────────────────────────────────────────────────

    override fun put(id: String, value: T) {
        checkOpen()
        require(id.isNotEmpty()) { "id must not be empty" }

        val fields = encoder(value)
        require(!fields.containsKey(embeddingField)) {
            "encode() returned a reserved field name '$embeddingField'; rename it"
        }

        val vi = vectorIndex
        val vec = embedder?.invoke(value)
        if (vi != null && vec != null) {
            // FT.HADD: synchronous HSET + index; populates hash + keeps the
            // index in sync. Caller-provided fields are passed as metadata.
            vi.add(id = "cs:$name:rec:$id", vector = vec, metadata = fields)
        } else {
            // Plain HSET — no vector index wiring.
            val hash = ns.hash(recordKey(id))
            if (fields.isNotEmpty()) hash.setAll(fields)
        }

        timeExtractor?.let { extract ->
            ns.sortedSet(timeIndexKey).add(score = extract(value).toDouble(), member = id)
        }
        tagsExtractor?.let { extract ->
            extract(value).forEach { tag ->
                ns.set(tagIndexKey(tag)).add(id)
            }
        }
    }

    override fun putAll(entries: Map<String, T>) {
        // For now, loop — each put may need a separate FT.HADD call.
        // A future optimization can batch plain-hash puts through
        // directPipelineArgs when no embedder is configured.
        for ((id, value) in entries) put(id, value)
    }

    override fun get(id: String): T? {
        checkOpen()
        // Phase 7 — prefer the snapshot-typed HGETALL when the record is
        // hot in the in-process cache. That path skips RESP encode on the
        // C side AND the RespParser walk on the Kotlin side, which was
        // the single largest regression the ContextStore incurred when
        // it was unified onto commandTyped(HGETALL). `getAllDirect` falls
        // back to the pipe automatically on a snapshot miss, so this is
        // safe to call unconditionally.
        val raw = ns.hash(recordKey(id)).getAllDirect()
        if (raw.isEmpty()) return null
        val clean = if (raw.containsKey(embeddingField)) raw.filterKeys { it != embeddingField } else raw
        return runCatching { decoder(clean) }.getOrNull()
    }

    override fun getAll(ids: List<String>): List<T?> = ids.map { get(it) }

    override fun delete(id: String): Boolean {
        checkOpen()
        val hash = ns.hash(recordKey(id))
        if (!hash.exists()) return false

        timeExtractor?.let {
            ns.sortedSet(timeIndexKey).remove(id)
        }
        tagsExtractor?.let {
            // We do not know which tags this doc had without reading it first;
            // fetch, decode, and unindex. Acceptable cost for delete.
            get(id)?.let { value ->
                tagsExtractor.invoke(value).forEach { tag ->
                    ns.set(tagIndexKey(tag)).remove(id)
                }
            }
        }

        hash.delete()
        return true
    }

    /** The Valkey prefix every primitive obtained from [ns] gets. SCAN
     *  responses return full keys (already prefixed), so this is what we
     *  strip to recover the caller-facing id or sub-key. */
    private val nsPrefix: String get() = "cs:$name:"

    override fun flush() {
        checkOpen()
        // Drop every record hash matching our prefix. SCAN responses come
        // back fully prefixed (e.g. "cs:sensors:rec:42") — hand them to the
        // un-namespaced Dazzle client so we don't double the prefix.
        for (batch in ns.scan(match = "rec:*", count = 200)) {
            for (fullKey in batch) dazzle.hash(fullKey).delete()
        }
        // Drop indices.
        ns.sortedSet(timeIndexKey).deleteKey()
        for (batch in ns.scan(match = "idx:tag:*", count = 200)) {
            for (fullKey in batch) dazzle.set(fullKey).deleteKey()
        }
        // Drop + recreate vector index (only way to ensure no stale entries).
        vectorIndex?.drop()
        vectorIndex?.create()
    }

    override fun count(): Long {
        checkOpen()
        var total = 0L
        for (batch in ns.scan(match = "rec:*", count = 500)) {
            total += batch.size
        }
        return total
    }

    override fun iterate(match: String?): Sequence<Pair<String, T>> = sequence {
        checkOpen()
        val pattern = match?.let { "rec:$it" } ?: "rec:*"
        for (batch in ns.scan(match = pattern, count = 200)) {
            for (fullKey in batch) {
                // fullKey = "cs:<name>:rec:<id>". Strip both layers to
                // recover the caller-facing id.
                val id = fullKey.removePrefix("${nsPrefix}rec:")
                val raw = dazzle.hash(fullKey).getAll()
                if (raw.isEmpty()) continue
                val clean = if (raw.containsKey(embeddingField)) raw.filterKeys { it != embeddingField } else raw
                runCatching { decoder(clean) }.onSuccess { yield(id to it) }
            }
        }
    }

    // ── Queries ───────────────────────────────────────────────────────────

    override fun semanticSearch(query: String, k: Int): List<Hit<T>> {
        val embed = embedder ?: return emptyList()
        // Semantic search with a String query requires hashing it through the
        // same embedder — but the embedder takes T, not String. So this
        // overload is not wired by default; callers should use the
        // vector-based overload. We log and return empty to signal.
        // Rationale: decoupling text→vector from T→vector is a conscious
        // design choice — the dev controls both.
        @Suppress("UNUSED_VARIABLE")
        val unused = embed
        return emptyList()
    }

    override fun semanticSearch(vector: FloatArray, k: Int): List<Hit<T>> {
        val vi = vectorIndex ?: return emptyList()
        require(vector.size == embeddingDim) {
            "query vector has ${vector.size} dims, store was built with $embeddingDim"
        }
        val raw = vi.search(query = vector, k = k)
        // `raw[i].id` is the full hash key (e.g. "cs:sensors:rec:42").
        // Reconstruct by stripping our prefix and fetching.
        return raw.mapNotNull { r ->
            val id = r.id.removePrefix("cs:$name:rec:")
            val value = get(id) ?: return@mapNotNull null
            Hit(id = id, score = r.score, value = value)
        }
    }

    override fun byTimeRange(start: Long, end: Long, limit: Int): List<Pair<String, T>> {
        if (timeExtractor == null) return emptyList()
        // Phase 2 fast path — rangeByScoreDirect reads ids from the
        // snapshot cache without the RESP encode/parse round-trip. Falls
        // back to rangeByScore automatically on a miss.
        val zset = ns.sortedSet(timeIndexKey)
        val ids = zset.rangeByScoreDirect(
            min = start.toDouble(),
            max = end.toDouble(),
        )
        return ids
            .take(limit)
            .mapNotNull { id -> get(id)?.let { id to it } }
    }

    override fun byTag(tag: String): Sequence<Pair<String, T>> = sequence {
        if (tagsExtractor == null) return@sequence
        // Phase 2 — tag index members read via the snapshot fast path.
        // Every get(id) inside the loop is also fast-path (Phase 7). The
        // whole sequence runs without a single RESP encode / parse now.
        val set = ns.set(tagIndexKey(tag))
        for (id in set.membersDirect()) {
            get(id)?.let { yield(id to it) }
        }
    }

    override fun byTags(allOf: Set<String>): Sequence<Pair<String, T>> = sequence {
        if (tagsExtractor == null || allOf.isEmpty()) return@sequence
        // Intersection of id sets across all tags — pick the smallest to
        // iterate, test membership in the rest. Smallest resolution still
        // goes via the pipe since cardinality is not snapshotted — only
        // ~1 extra RESP roundtrip per call, dwarfed by the per-id fast
        // path read loop.
        val sets = allOf.map { ns.set(tagIndexKey(it)) }
        val smallest = sets.minByOrNull { it.cardinality() } ?: return@sequence
        for (id in smallest.membersDirect()) {
            if (sets.all { it.contains(id) }) {
                get(id)?.let { yield(id to it) }
            }
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            // Nothing to release at the JVM level — VectorIndex handles are
            // owned by the native library and freed on server stop. Flagging
            // closed so put/get/etc. throw clearly instead of silently
            // operating on a store the caller thinks is dead.
        }
    }

    private fun checkOpen() {
        if (closed.get()) error("ContextStore '$name' is closed")
    }

    // ── Key helpers ───────────────────────────────────────────────────────

    private fun recordKey(id: String) = "rec:$id"
    private val timeIndexKey = "idx:time"
    private fun tagIndexKey(tag: String) = "idx:tag:$tag"
}

// ── Blob encoding helper (internal, used by DazzleContextStore callers
//    that want to build a raw embedding blob outside the normal add() path). ──
internal fun FloatArray.toBase64Blob(): String {
    val buf = ByteBuffer.allocate(size * 4).order(ByteOrder.LITTLE_ENDIAN)
    forEach { buf.putFloat(it) }
    return Base64.encodeToString(buf.array(), Base64.NO_WRAP)
}
