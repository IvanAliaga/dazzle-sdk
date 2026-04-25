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
 * Type-safe wrapper around a Valkey list. Obtain via `valkey.list("key")`.
 *
 * Lists are doubly-linked queues — push/pop is O(1) at either end, and
 * range queries are O(S+N). Perfect for append-only logs like
 * `agent:decisions` where you want to read the full history later.
 *
 * ```kotlin
 * val decisions = valkey.list("agent:decisions")
 *
 * decisions.rpush("CP1: anomaly=no")
 * decisions.rpush("CP2: anomaly=yes")
 *
 * val all = decisions.range(0, -1)          // full list
 * val latest = decisions.index(-1)          // last entry
 * val count = decisions.length()            // Long
 * ```
 */
class ListKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {

    /** RPUSH key v1 [v2 …] — append at the tail, returns the new length. */
    fun rpush(vararg values: String): Long {
        if (values.isEmpty()) return 0L
        val args = arrayOf("RPUSH", key, *values)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** LPUSH key v1 [v2 …] — prepend at the head, returns the new length. */
    fun lpush(vararg values: String): Long {
        if (values.isEmpty()) return 0L
        val args = arrayOf("LPUSH", key, *values)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** RPOP key — pop from the tail. Null if the list is empty. */
    fun rpop(): String? =
        server.commandTyped("RPOP", key).asBulkOrNull()

    /** LPOP key — pop from the head. Null if the list is empty. */
    fun lpop(): String? =
        server.commandTyped("LPOP", key).asBulkOrNull()

    /**
     * LRANGE key start stop — inclusive range in insertion order. Use
     * `0..-1` to get the whole list; negative indices count from the tail.
     */
    fun range(start: Long, stop: Long): List<String> =
        server.commandTyped("LRANGE", key, start.toString(), stop.toString())
            .asArray()
            .mapNotNull { it.asBulkOrNull() }

    /** LLEN key — total number of elements. */
    fun length(): Long =
        server.commandTyped("LLEN", key).asLongOrNull() ?: 0L

    /** LTRIM key start stop — keep only the elements in [start, stop]. */
    fun trim(start: Long, stop: Long): Boolean {
        val r = server.commandTyped("LTRIM", key, start.toString(), stop.toString())
        return (r as? RespValue.SimpleString)?.value == "OK"
    }

    /** LINDEX key idx — element at position idx (0-based), null if out of range. */
    fun index(idx: Long): String? =
        server.commandTyped("LINDEX", key, idx.toString()).asBulkOrNull()

    /** LSET key idx value — overwrite element at idx. Returns true on success. */
    fun set(idx: Long, value: String): Boolean {
        val r = server.commandTyped("LSET", key, idx.toString(), value)
        return (r as? RespValue.SimpleString)?.value == "OK"
    }

    /**
     * LREM key count value — remove up to [count] occurrences. If count > 0
     * scans head→tail, if count < 0 scans tail→head, if count == 0 removes
     * every occurrence. Returns the number actually removed.
     */
    fun remove(count: Long, value: String): Long =
        server.commandTyped("LREM", key, count.toString(), value).asLongOrNull() ?: 0L

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}
