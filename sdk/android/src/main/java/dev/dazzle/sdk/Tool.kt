// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

/**
 * A typed function that an LLM / [Agent] can invoke during a conversation.
 *
 * Serializes to the **OpenAI / Anthropic / Gemini function-calling format**
 * via [toDeclaration], so a `Tool` written in Kotlin is consumed as-is by
 * every modern LLM runtime: LiteRT-LM, llama.cpp, Ollama, vLLM, or a
 * hosted API.
 *
 * ## Shape
 *
 * `Args` is whatever typed input the tool needs (typically a `data class`).
 * `Ret` is the value returned to the caller. Both are bridged via
 * [argsFromJson] / [returnToJson] — the dev controls the exact JSON layout
 * so there's no hidden encoding magic.
 *
 * ## Example
 *
 * ```kotlin
 * data class WeatherQuery(val city: String, val unit: String = "C")
 * data class WeatherReport(val tempC: Double, val condition: String)
 *
 * val weatherTool = object : Tool<WeatherQuery, WeatherReport> {
 *     override val name = "weather.get"
 *     override val description = "Return the current weather for a city."
 *     override val argsSchema = jsonSchemaObject {
 *         property("city", type = "string", required = true,
 *                  description = "City name, e.g. 'Lima'")
 *         property("unit", type = "string", required = false,
 *                  description = "Temperature unit: C or F")
 *     }
 *     override suspend fun invoke(args: WeatherQuery, ctx: ToolContext): WeatherReport =
 *         myWeatherApi.fetch(args.city, args.unit)
 *
 *     override fun argsFromJson(raw: String): WeatherQuery = parseJson(raw)
 *     override fun returnToJson(value: WeatherReport): String = toJson(value)
 * }
 * ```
 */
interface Tool<Args, Ret> {
    /** Canonical identifier the LLM references in tool_calls. Must be
     *  unique within an [Agent]'s tool set; convention is `domain.verb`. */
    val name: String

    /** Natural-language description the LLM reads to decide *when* to
     *  invoke this tool. Keep it concise (≤200 chars) and action-oriented. */
    val description: String

    /** JSON Schema describing the shape of [Args]. Used by the model to
     *  produce well-formed tool_calls and by the caller to validate before
     *  dispatch. See [jsonSchemaObject] for a minimal builder. */
    val argsSchema: JsonSchema

    /** Execute the tool. Called after [argsFromJson] decodes the LLM's
     *  tool_call arguments into typed [Args]. The [ctx] grants access to
     *  the agent's stores and execution policy. */
    suspend fun invoke(args: Args, ctx: ToolContext): Ret

    /** Decode a tool_call's `arguments` JSON (which the LLM produced per
     *  [argsSchema]) into typed [Args]. Throws if the JSON is malformed. */
    fun argsFromJson(raw: String): Args

    /** Encode the return value back to a JSON string that the SDK appends
     *  as the `content` of a `Role.tool` response message. */
    fun returnToJson(value: Ret): String

    /** Serialize to the shape every LLM tool-calling API expects:
     *  `{ "name": ..., "description": ..., "parameters": <JSON Schema> }`. */
    fun toDeclaration(): ToolDeclaration =
        ToolDeclaration(name = name, description = description, parameters = argsSchema)
}

/**
 * Wire-format tool declaration. Serialize to JSON and paste directly into
 * an OpenAI `tools: [...]` array — no adapter needed.
 *
 * ```json
 * { "name": "weather.get",
 *   "description": "Return the current weather for a city.",
 *   "parameters": { "type": "object", "properties": {...}, "required": [...] } }
 * ```
 */
data class ToolDeclaration(
    val name: String,
    val description: String,
    val parameters: JsonSchema,
)

/**
 * Execution context available inside [Tool.invoke]. Gives the tool access
 * to the agent's shared context stores and execution policy without
 * exposing the whole Dazzle surface.
 */
class ToolContext(
    /** Threading / concurrency settings inherited from the agent. */
    val execution: ExecutionPolicy,

    /** Named context stores the tool can read from or write to. Keys are
     *  whatever the agent's builder registered. Typical keys: `"memory"`
     *  (chat turns), `"knowledge"` (RAG documents), `"sensors"` (domain). */
    val stores: Map<String, ContextStore<*>>,

    /** Reserved for multi-agent pub/sub. When null, publishing is a no-op.
     *  Typed shape lands in a future `Channel<T>` follow-up. */
    val publish: (suspend (channel: String, message: String) -> Unit)? = null,
)

/**
 * Minimal JSON Schema representation — just enough to describe tool
 * parameter shapes without pulling a full JSON Schema implementation.
 *
 * Three levels suffice for 95% of tools:
 *
 *   - [ObjectSchema]: a parameters object with named fields
 *   - [PrimitiveSchema]: `string`, `integer`, `number`, `boolean`
 *   - [ArraySchema]: lists of a single item shape
 *
 * Serialized to the JSON string expected by OpenAI / Anthropic via
 * [serialize]. Kept intentionally loose — devs who need `anyOf`, `$ref`,
 * etc. can subclass and emit their own JSON.
 */
sealed class JsonSchema {

    /** Emit this schema as a JSON string (OpenAI-compatible). */
    abstract fun serialize(): String

    data class ObjectSchema(
        val properties: Map<String, JsonSchema>,
        val required: List<String> = emptyList(),
        val description: String? = null,
    ) : JsonSchema() {
        override fun serialize(): String = buildString {
            append("{\"type\":\"object\",")
            description?.let { append("\"description\":\"${escapeJson(it)}\",") }
            append("\"properties\":{")
            properties.entries.forEachIndexed { i, (k, v) ->
                if (i > 0) append(',')
                append('"'); append(escapeJson(k)); append("\":"); append(v.serialize())
            }
            append('}')
            if (required.isNotEmpty()) {
                append(",\"required\":[")
                required.forEachIndexed { i, r ->
                    if (i > 0) append(',')
                    append('"'); append(escapeJson(r)); append('"')
                }
                append(']')
            }
            append('}')
        }
    }

    data class PrimitiveSchema(
        val type: String,                      // "string" / "integer" / "number" / "boolean"
        val description: String? = null,
        val enum: List<String>? = null,
        val minimum: Double? = null,
        val maximum: Double? = null,
    ) : JsonSchema() {
        init {
            require(type in setOf("string", "integer", "number", "boolean")) {
                "unsupported primitive type: $type"
            }
        }
        override fun serialize(): String = buildString {
            append("{\"type\":\"").append(type).append('"')
            description?.let { append(",\"description\":\"").append(escapeJson(it)).append('"') }
            enum?.let {
                append(",\"enum\":[")
                it.forEachIndexed { i, e ->
                    if (i > 0) append(',')
                    append('"'); append(escapeJson(e)); append('"')
                }
                append(']')
            }
            minimum?.let { append(",\"minimum\":").append(it) }
            maximum?.let { append(",\"maximum\":").append(it) }
            append('}')
        }
    }

    data class ArraySchema(
        val items: JsonSchema,
        val description: String? = null,
    ) : JsonSchema() {
        override fun serialize(): String = buildString {
            append("{\"type\":\"array\",\"items\":").append(items.serialize())
            description?.let { append(",\"description\":\"").append(escapeJson(it)).append('"') }
            append('}')
        }
    }

    /**
     * Pass-through schema that already ships as a JSON string — used
     * by the Flutter / React Native bridges where the consumer builds
     * the schema in Dart / TypeScript and the native layer only needs
     * to forward it verbatim into the LLM prompt. Consumers of the
     * Kotlin SDK directly should stick to the typed variants above.
     */
    data class RawSchema(val json: String) : JsonSchema() {
        override fun serialize(): String = json
    }

    companion object {
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
    }
}

// ── Minimal DSL for building an ObjectSchema — no third-party deps ──────

/**
 * Build an [JsonSchema.ObjectSchema] with a fluent-ish API.
 *
 * ```kotlin
 * val schema = jsonSchemaObject(description = "Weather query") {
 *     property("city", type = "string", required = true, description = "city name")
 *     property("unit", type = "string", description = "C or F", enum = listOf("C", "F"))
 * }
 * ```
 */
fun jsonSchemaObject(
    description: String? = null,
    build: JsonSchemaObjectBuilder.() -> Unit,
): JsonSchema.ObjectSchema = JsonSchemaObjectBuilder(description).apply(build).build()

class JsonSchemaObjectBuilder internal constructor(private val description: String?) {
    private val props = linkedMapOf<String, JsonSchema>()
    private val reqList = mutableListOf<String>()

    @JvmOverloads
    fun property(
        name: String,
        type: String,
        description: String? = null,
        required: Boolean = false,
        enum: List<String>? = null,
        minimum: Double? = null,
        maximum: Double? = null,
    ) {
        props[name] = JsonSchema.PrimitiveSchema(
            type = type,
            description = description,
            enum = enum,
            minimum = minimum,
            maximum = maximum,
        )
        if (required) reqList += name
    }

    fun property(name: String, schema: JsonSchema, required: Boolean = false) {
        props[name] = schema
        if (required) reqList += name
    }

    internal fun build() = JsonSchema.ObjectSchema(
        properties = props,
        required = reqList.toList(),
        description = description,
    )
}
