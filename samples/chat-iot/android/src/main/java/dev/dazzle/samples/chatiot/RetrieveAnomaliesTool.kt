// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatiot

import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.JsonSchema
import dev.dazzle.sdk.Tool
import dev.dazzle.sdk.ToolContext
import dev.dazzle.sdk.jsonSchemaObject
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Tool the LLM calls when the user asks about sensor data.
 *
 * Wire-format (OpenAI-compatible):
 * ```
 * retrieve_anomalies(min_from: integer, min_to: integer)
 *   → [{start_minute, end_minute, avg_temp_c, max_temp_c, avg_humidity,
 *       anomaly_detected, anomaly_type, summary}]
 * ```
 *
 * Implementation stays entirely on the snapshot-cache RESP-free path:
 *
 *   1. `sset.rangeByScoreDirect(min..max)` returns SHORT IDs
 *      (e.g. "w-0195") — snapshot cache HIT, zero RESP.
 *   2. For each ID, `hash.getAllDirect()` reads the payload fields
 *      directly out of the cache — also zero RESP.
 *
 * This is the storage pattern the paper benchmarks at 150 µs / query
 * on a Moto G35 and 33 µs on an iPhone 12 Pro.
 */
class RetrieveAnomaliesTool : Tool<TimeRange, List<IoTWindow>> {

    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint       = false
    }

    override val name        = "retrieve_anomalies"
    override val description = """
        Return the sensor windows overlapping [min_from..min_to] from
        the on-device Dazzle store. Each row includes averages, anomaly
        flag, and a one-line summary. Minutes are 0..2399.
    """.trimIndent()

    override val argsSchema: JsonSchema = jsonSchemaObject(
        description = "Time range (in minutes) to inspect.",
    ) {
        property("min_from", type = "integer",
                 description = "Lower-bound minute, inclusive (0..2399).",
                 required = true,
                 minimum = 0.0, maximum = 2399.0)
        property("min_to", type = "integer",
                 description = "Upper-bound minute, inclusive (0..2399).",
                 required = true,
                 minimum = 0.0, maximum = 2399.0)
    }

    override fun argsFromJson(raw: String): TimeRange =
        json.decodeFromString(TimeRange.serializer(), raw)

    override suspend fun invoke(args: TimeRange, ctx: ToolContext): List<IoTWindow> {
        val client = DazzleServer.client()
        val sset   = client.sortedSet(IotCorpus.sortedSetKey)

        // 1) Fast-path range read → short IDs, snapshot-cache HIT.
        val ids = sset.rangeByScoreDirect(
            min = args.min_from.toDouble(),
            max = args.min_to.toDouble(),
        )

        // 2) Hydrate each ID → full window via `hgetAllDirect`, also
        //    snapshot-cache HIT. Zero RESP on either read.
        return ids.mapNotNull { id ->
            val fields = client.hash("${IotCorpus.hashPrefix}$id").getAllDirect()
            if (fields.isEmpty()) null else hydrate(fields)
        }
    }

    private fun hydrate(f: Map<String, String>): IoTWindow? = runCatching {
        IoTWindow(
            start_minute     = f.getValue("start_minute").toInt(),
            end_minute       = f.getValue("end_minute").toInt(),
            avg_temp_c       = f.getValue("avg_temp_c").toDouble(),
            max_temp_c       = f.getValue("max_temp_c").toDouble(),
            min_temp_c       = f.getValue("min_temp_c").toDouble(),
            avg_humidity     = f.getValue("avg_humidity").toDouble(),
            anomaly_detected = f.getValue("anomaly_detected").toBoolean(),
            anomaly_type     = f["anomaly_type"] ?: "none",
            summary          = f["summary"] ?: "",
        )
    }.getOrNull()

    override fun returnToJson(value: List<IoTWindow>): String =
        json.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(IoTWindow.serializer()),
            value,
        )
}

@Serializable
data class TimeRange(
    val min_from: Int,
    val min_to:   Int,
)
