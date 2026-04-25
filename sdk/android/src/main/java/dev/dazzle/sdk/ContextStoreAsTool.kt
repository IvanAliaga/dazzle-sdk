// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

/** Arguments for the built-in semantic-search tool — a single query
 *  string. Simple enough that the SDK ships its own JSON codec so the
 *  caller doesn't need to pull Gson / Moshi for this common case. */
data class SemanticSearchArgs(val query: String)

/**
 * Expose a [ContextStore] as a [Tool] the LLM can invoke for
 * semantic recall / RAG.
 *
 * ```kotlin
 * val chatMemoryTool = chatMemory.asSemanticSearchTool(
 *     toolName = "chat.recall",
 *     description = "Retrieve past chat turns relevant to the user's query.",
 *     k = 5,
 *     embedder = { text -> myEmbedder.embed(text) },
 *     formatHit = { hit -> "${hit.value.role}: ${hit.value.text}" },
 * )
 *
 * agent.tools += chatMemoryTool
 * ```
 *
 * @param embedder how to turn the incoming query string into a vector.
 *        The store's own embedder takes `T`, not String, so the tool
 *        needs a separate text-to-vector path (usually the same embedder
 *        instance used when populating the store).
 * @param formatHit how each [Hit] is flattened into a string that goes
 *        back to the LLM. Default is `value.toString()`; most callers
 *        override to produce a compact per-line summary.
 */
@JvmOverloads
fun <T> ContextStore<T>.asSemanticSearchTool(
    toolName: String,
    description: String,
    k: Int = 5,
    embedder: (String) -> FloatArray,
    formatHit: (Hit<T>) -> String = { it.value.toString() },
): Tool<SemanticSearchArgs, List<String>> {
    val store = this
    return object : Tool<SemanticSearchArgs, List<String>> {
        override val name: String = toolName
        override val description: String = description
        override val argsSchema: JsonSchema = jsonSchemaObject {
            property(
                name = "query",
                type = "string",
                description = "Natural-language query to search the store with",
                required = true,
            )
        }

        override suspend fun invoke(args: SemanticSearchArgs, ctx: ToolContext): List<String> {
            val vector = embedder(args.query)
            return store.semanticSearch(vector, k = k).map(formatHit)
        }

        override fun argsFromJson(raw: String): SemanticSearchArgs {
            // Minimalist extraction — the schema has ONE string property.
            // We parse just the `"query": "..."` field without pulling a
            // full JSON parser dependency.
            return SemanticSearchArgs(query = extractStringField(raw, "query") ?: "")
        }

        override fun returnToJson(value: List<String>): String = buildString {
            append('[')
            value.forEachIndexed { i, s ->
                if (i > 0) append(',')
                append('"'); append(escapeJson(s)); append('"')
            }
            append(']')
        }
    }
}

// ── Minimal JSON helpers — enough for the fixed shape this file uses ─────

private fun extractStringField(json: String, field: String): String? {
    // Find `"field"` anchor, then the colon, then a quoted string.
    val anchor = "\"${field.replace("\"", "\\\"")}\""
    val start = json.indexOf(anchor).takeIf { it >= 0 } ?: return null
    var i = start + anchor.length
    while (i < json.length && json[i].isWhitespace()) i++
    if (i >= json.length || json[i] != ':') return null
    i++
    while (i < json.length && json[i].isWhitespace()) i++
    if (i >= json.length || json[i] != '"') return null
    i++
    val sb = StringBuilder()
    while (i < json.length) {
        val c = json[i]
        if (c == '\\' && i + 1 < json.length) {
            when (val esc = json[i + 1]) {
                '"'  -> sb.append('"')
                '\\' -> sb.append('\\')
                'n'  -> sb.append('\n')
                'r'  -> sb.append('\r')
                't'  -> sb.append('\t')
                else -> sb.append(esc)
            }
            i += 2
        } else if (c == '"') {
            return sb.toString()
        } else {
            sb.append(c)
            i++
        }
    }
    return null   // unterminated string
}

private fun escapeJson(s: String): String = buildString(s.length) {
    for (c in s) when (c) {
        '"'  -> append("\\\"")
        '\\' -> append("\\\\")
        '\n' -> append("\\n")
        '\r' -> append("\\r")
        '\t' -> append("\\t")
        else -> append(c)
    }
}
