// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatkb

import android.content.Context
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.VectorIndex
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlin.math.sqrt

/**
 * Loads `dazzle_faq.json` from assets into a Dazzle HNSW_SQ8 vector
 * index on first launch. Uses the bundled `miniEmbed` hash-bucket
 * embedder so the demo has no second model weight to ship.
 */
object KbCorpus {

    const val INDEX_NAME     = "kb"
    const val HASH_PREFIX    = "samples:kb:"
    const val EMBEDDING_DIM  = 384

    @Volatile private var loaded = false
    @Volatile private var entriesByKey: Map<String, FaqEntry> = emptyMap()

    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint       = false
    }

    @Synchronized
    fun loadIntoDazzle(context: Context) {
        if (loaded) return

        val raw = context.assets.open("dazzle_faq.json")
            .bufferedReader()
            .use { it.readText() }
        val faqs = json.decodeFromString(
            ListSerializer(FaqEntry.serializer()), raw)

        val client = DazzleServer.client()
        val idx = client.vectorIndex(
            name             = INDEX_NAME,
            hashPrefix       = HASH_PREFIX,
            vectorField      = "emb",
            dim              = EMBEDDING_DIM,
            algorithm        = VectorIndex.Algorithm.HNSW_SQ8,
            metric           = VectorIndex.Metric.COSINE,
            initialCapacity  = faqs.size,
        )
        check(idx.create()) { "vector index create failed" }

        val ids = faqs.map { "$HASH_PREFIX${it.id}" }.toTypedArray()
        val vectors = faqs.map { miniEmbed("${it.question} ${it.answer}") }
            .toTypedArray()
        idx.addBatchDirect(ids, vectors)

        entriesByKey = faqs.associateBy { "$HASH_PREFIX${it.id}" }
        loaded = true
    }

    fun entry(forKey: String): FaqEntry? = entriesByKey[forKey]
}

@Serializable
data class FaqEntry(
    val id:       String,
    val category: String,
    val question: String,
    val answer:   String,
)

// ─── Minimal deterministic embedder ───────────────────────────────────────
//
// Hash-bucket "bag of tokens" embedder: tokenise input, bucket each
// token into `EMBEDDING_DIM` slots via FNV-1a, L2-normalise. Not a
// contextual embedder — for production, swap in a real one (BGE-small
// via llama.cpp --embedding, or a server-side Inference API). This
// exists only so the sample runs with zero extra downloads.

fun miniEmbed(text: String): FloatArray {
    val dim = KbCorpus.EMBEDDING_DIM
    val vec = FloatArray(dim)

    val tokens = text.lowercase()
        .split(Regex("[^a-z0-9]+"))
        .filter { it.isNotEmpty() }

    if (tokens.isEmpty()) {
        vec[0] = 1f   // avoid all-zero vector
        return vec
    }

    for (tok in tokens) {
        var hash = 0xcbf29ce484222325UL
        for (byte in tok.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toULong() and 0xFFu)
            hash = hash * 0x00000100000001B3UL
        }
        val bucket = (hash % dim.toULong()).toInt()
        val sign = if (((hash shr 32) and 1UL) == 0UL) 1f else -1f
        vec[bucket] += sign
    }

    // L2 normalise
    var norm = 0f
    for (x in vec) norm += x * x
    if (norm > 0f) {
        val inv = 1f / sqrt(norm)
        for (i in vec.indices) vec[i] *= inv
    }
    return vec
}
