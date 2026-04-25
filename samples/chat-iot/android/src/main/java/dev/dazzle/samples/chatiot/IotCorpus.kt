// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatiot

import android.content.Context
import dev.dazzle.sdk.DazzleServer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Loads the bundled `iot_windows.json` dataset into Dazzle using the
 * **production-grade storage pattern** the paper benchmarks call
 * out: SHORT IDs in the SortedSet, FULL payload in a HashKey.
 *
 * ```
 * ZSet  samples:iot:windows           score=start_minute, member="w-<n>"
 * Hash  samples:iot:win:w-<n>         { start_minute, end_minute,
 *                                       avg_temp_c, ..., summary }
 * ```
 *
 * Why this matters: the Dazzle snapshot-cache typed path
 * (`rangeByScoreDirect`, `hgetAllDirect`) caps members at 128 B. A
 * naïve approach that stores the JSON window (~200 B) straight in
 * the ZSet falls off that path and pays RESP encode/decode on every
 * read (~150 µs + UTF-8 parse). Splitting into a short ID + parallel
 * Hash keeps both reads on the fast path (~2 µs snapshot hit each,
 * 30 rows ≈ 100 µs total). In production this is the difference
 * between a snappy assistant turn and a laggy one.
 */
object IotCorpus {

    const val sortedSetKey = "samples:iot:windows"
    const val hashPrefix   = "samples:iot:win:"

    private var loaded = false
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint       = false
    }

    @Synchronized
    fun loadIntoDazzle(context: Context) {
        if (loaded) return

        val raw = context.assets.open("iot_windows.json")
            .bufferedReader()
            .use { it.readText() }

        val windows = json.decodeFromString<List<IoTWindow>>(raw)

        val client = DazzleServer.client()
        val sset = client.sortedSet(sortedSetKey)

        // Fresh load every install — 30 rows is cheap. Production apps
        // gate this behind a version/hash check.
        client.delete(sortedSetKey)
        for (win in windows) {
            val id = windowId(win.start_minute)
            // Wipe any stale hash for this ID before the fresh write.
            client.delete("$hashPrefix$id")
            sset.add(score = win.start_minute.toDouble(), member = id)
            val hash = client.hash("$hashPrefix$id")
            hash.setAll(linkedMapOf(
                "start_minute"     to win.start_minute.toString(),
                "end_minute"       to win.end_minute.toString(),
                "avg_temp_c"       to win.avg_temp_c.toString(),
                "max_temp_c"       to win.max_temp_c.toString(),
                "min_temp_c"       to win.min_temp_c.toString(),
                "avg_humidity"     to win.avg_humidity.toString(),
                "anomaly_detected" to win.anomaly_detected.toString(),
                "anomaly_type"     to win.anomaly_type,
                "summary"          to win.summary,
            ))
        }
        loaded = true
    }

    /** Short ID: 4-digit zero-padded minute → "w-0195". Max 8 bytes,
     *  well inside the 128-byte snapshot-cache limit. */
    fun windowId(startMinute: Int): String =
        "w-${startMinute.toString().padStart(4, '0')}"
}

@Serializable
data class IoTWindow(
    val start_minute:      Int,
    val end_minute:        Int,
    val avg_temp_c:        Double,
    val max_temp_c:        Double,
    val min_temp_c:        Double,
    val avg_humidity:      Double,
    val anomaly_detected:  Boolean,
    val anomaly_type:      String,
    val summary:           String,
)
