// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatkb

import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.JsonSchema
import dev.dazzle.sdk.Tool
import dev.dazzle.sdk.ToolContext
import dev.dazzle.sdk.VectorIndex
import dev.dazzle.sdk.jsonSchemaObject
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Tool the LLM calls when the user asks about Dazzle itself.
 *
 * Wire-format (OpenAI-compatible):
 * ```
 * search_kb(query: string, k: integer)
 *   → [{id, category, question, answer, score}]
 * ```
 */
class SearchKbTool : Tool<SearchQuery, List<FaqHit>> {

    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint       = false
    }

    override val name        = "search_kb"
    override val description = """
        Look up the top-k most relevant Dazzle FAQ rows for a natural-
        language query. Use this whenever the user asks about Dazzle
        the product, the SDK API, the four LLM adapters, the benchmarks,
        or the HNSW variants. Returns the FAQ question, full answer,
        and a similarity score (lower is closer).
    """.trimIndent()

    override val argsSchema: JsonSchema = jsonSchemaObject(
        description = "Semantic search over the on-device Dazzle FAQ.",
    ) {
        property("query", type = "string",
                 description = "The user's question, verbatim or paraphrased.",
                 required = true)
        property("k", type = "integer",
                 description = "Number of FAQ rows to return (1..10).",
                 required = false,
                 minimum = 1.0, maximum = 10.0)
    }

    override fun argsFromJson(raw: String): SearchQuery =
        json.decodeFromString(SearchQuery.serializer(), raw)

    override suspend fun invoke(args: SearchQuery, ctx: ToolContext): List<FaqHit> {
        val k = (args.k ?: 5).coerceIn(1, 10)
        val vec = miniEmbed(args.query)

        val idx = DazzleServer.client().vectorIndex(
            name        = KbCorpus.INDEX_NAME,
            hashPrefix  = KbCorpus.HASH_PREFIX,
            vectorField = "emb",
            dim         = KbCorpus.EMBEDDING_DIM,
            algorithm   = VectorIndex.Algorithm.HNSW_SQ8,
            metric      = VectorIndex.Metric.COSINE,
        )
        val results = idx.searchDirect(vec, k, efRuntime = 10)

        return results.mapNotNull { (key, distance) ->
            KbCorpus.entry(key)?.let {
                FaqHit(
                    id       = it.id,
                    category = it.category,
                    question = it.question,
                    answer   = it.answer,
                    score    = distance,
                )
            }
        }
    }

    override fun returnToJson(value: List<FaqHit>): String =
        json.encodeToString(ListSerializer(FaqHit.serializer()), value)
}

@Serializable
data class SearchQuery(
    val query: String,
    val k:     Int? = null,
)

@Serializable
data class FaqHit(
    val id:       String,
    val category: String,
    val question: String,
    val answer:   String,
    val score:    Float,
)
