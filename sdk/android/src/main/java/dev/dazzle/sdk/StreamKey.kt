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

package dev.dazzle.sdk

/**
 * Type-safe wrapper around a Valkey stream. Obtain via `valkey.stream("key")`.
 *
 * Streams are Valkey's ordered, append-only log primitive with native
 * bounded-size (`MAXLEN`) support — the right fit for sensor ingestion,
 * event logs, and anything else that's time-ordered and needs a tail
 * bound without an application-level trim job.
 *
 * Each stream entry has an auto-assigned ID (`<ms>-<seq>`) and a map of
 * field/value pairs. [Entry] is the decoded form returned by the range
 * queries.
 *
 * ```kotlin
 * val readings = valkey.stream("sensor:readings")
 *
 * readings.add(
 *     fields = mapOf("temp" to "22.3", "humidity" to "48", "minute" to "19"),
 *     maxLen = 200,
 * )
 * val lengh = readings.length()           // Long
 * val last10 = readings.revRange(count = 10)      // List<Entry>, newest first
 * val oldest = readings.range(count = 5)          // List<Entry>, oldest first
 * ```
 */
class StreamKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {
    /** A single decoded stream entry. [id] is Valkey's `<ms>-<seq>` ID; [fields]
     *  preserves insertion order. */
    data class Entry(val id: String, val fields: Map<String, String>)

    /** MAXLEN trim strategy. APPROX (`~`) is faster and usually good enough; EXACT (`=`) is slower. */
    enum class TrimStrategy { APPROX, EXACT }

    /**
     * XADD key [MAXLEN [~|=] count] * field value …
     *
     * @param fields field/value pairs to store in this entry
     * @param maxLen optional bound on stream length — Valkey trims older
     *        entries to keep the total at or below this size
     * @param trimStrategy EXACT (`=`) for strict bounds or APPROX (`~`)
     *        for faster node-level trimming (default)
     * @param id entry ID or `*` for auto-assign (default)
     * @return the assigned entry ID, or null if the server returned an unexpected reply
     */
    fun add(
        fields: Map<String, String>,
        maxLen: Long? = null,
        trimStrategy: TrimStrategy = TrimStrategy.APPROX,
        id: String = "*",
    ): String? {
        if (fields.isEmpty()) return null
        val args = mutableListOf("XADD", key)
        if (maxLen != null) {
            args += "MAXLEN"
            args += if (trimStrategy == TrimStrategy.APPROX) "~" else "="
            args += maxLen.toString()
        }
        args += id
        for ((k, v) in fields) { args += k; args += v }
        return server.commandTyped(*args.toTypedArray()).asBulkOrNull()
    }

    /** XLEN key */
    fun length(): Long =
        server.commandTyped("XLEN", key).asLongOrNull() ?: 0L

    /**
     * XRANGE key start end [COUNT count] — entries in insertion order
     * (oldest first). Default range is the whole stream.
     */
    fun range(start: String = "-", end: String = "+", count: Long? = null): List<Entry> {
        val args = mutableListOf("XRANGE", key, start, end)
        if (count != null) { args += "COUNT"; args += count.toString() }
        return parseEntries(server.commandTyped(*args.toTypedArray()))
    }

    /**
     * XREVRANGE key end start [COUNT count] — entries in reverse order
     * (newest first). Default range is the whole stream.
     */
    fun revRange(end: String = "+", start: String = "-", count: Long? = null): List<Entry> {
        val args = mutableListOf("XREVRANGE", key, end, start)
        if (count != null) { args += "COUNT"; args += count.toString() }
        return parseEntries(server.commandTyped(*args.toTypedArray()))
    }

    /** XTRIM key MAXLEN [~|=] count — returns the number of entries evicted. */
    fun trim(maxLen: Long, strategy: TrimStrategy = TrimStrategy.APPROX): Long {
        val flag = if (strategy == TrimStrategy.APPROX) "~" else "="
        return server.commandTyped("XTRIM", key, "MAXLEN", flag, maxLen.toString())
            .asLongOrNull() ?: 0L
    }

    /** XDEL key id [id …] — returns the number of entries actually deleted. */
    fun delete(vararg ids: String): Long {
        if (ids.isEmpty()) return 0L
        val args = arrayOf("XDEL", key, *ids)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    /** DEL — delete the entire stream. Returns true if the key existed. */
    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    /** EXISTS — whether the stream exists at all. */
    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L

    // ── Private decoders ──────────────────────────────────────────────────

    /**
     * Parses the RESP reply of XRANGE / XREVRANGE into a list of [Entry].
     * The reply shape is an array of `[id, [f1, v1, f2, v2, …]]` pairs.
     */
    private fun parseEntries(reply: RespValue): List<Entry> {
        val outer = reply.asArray()
        val result = ArrayList<Entry>(outer.size)
        for (item in outer) {
            val pair = item.asArray()
            if (pair.size < 2) continue
            val id = pair[0].asBulkOrNull() ?: continue
            val fieldItems = pair[1].asArray()
            val fields = linkedMapOf<String, String>()
            var i = 0
            while (i < fieldItems.size - 1) {
                val k = fieldItems[i].asBulkOrNull() ?: ""
                val v = fieldItems[i + 1].asBulkOrNull() ?: ""
                fields[k] = v
                i += 2
            }
            result += Entry(id = id, fields = fields)
        }
        return result
    }
}
