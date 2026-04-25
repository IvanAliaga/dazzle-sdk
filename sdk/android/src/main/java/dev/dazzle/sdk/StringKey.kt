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
 * Type-safe wrapper around a Valkey string key. Obtain via
 * `valkey.string("key")`.
 *
 * "String" in Valkey is really "blob" — any sequence of bytes up to
 * 512 MB. Common uses are counters (via [incrBy]), session tokens, and
 * cached payloads with an optional TTL.
 *
 * ```kotlin
 * val counter = valkey.string("sessions:active")
 *
 * counter.set("0")
 * counter.incrBy(1)
 * counter.incrBy(1)
 * val n = counter.get()?.toLongOrNull() ?: 0L   // 2
 * ```
 */
class StringKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {
    /** Options for SET: NX (only if absent), XX (only if present), EX / PX (TTL). */
    data class SetOptions(
        val onlyIfAbsent: Boolean = false,   // NX
        val onlyIfPresent: Boolean = false,  // XX
        val ttlSeconds: Long? = null,        // EX
        val ttlMillis: Long? = null,         // PX
    )

    /**
     * SET key value [EX seconds | PX ms] [NX | XX]
     *
     * Returns true if the write happened, false if an NX/XX guard
     * blocked it.
     */
    fun set(value: String, options: SetOptions = SetOptions()): Boolean {
        val args = mutableListOf("SET", key, value)
        options.ttlSeconds?.let { args += "EX"; args += it.toString() }
        options.ttlMillis?.let { args += "PX"; args += it.toString() }
        if (options.onlyIfAbsent)  args += "NX"
        if (options.onlyIfPresent) args += "XX"

        val r = server.commandTyped(*args.toTypedArray())
        // NX/XX rejection replies with a null bulk; OK replies with +OK
        return when (r) {
            is RespValue.SimpleString -> r.value == "OK"
            is RespValue.Bulk -> !r.isNull
            else -> false
        }
    }

    /** GET key — null if the key does not exist. */
    fun get(): String? =
        server.commandTyped("GET", key).asBulkOrNull()

    /**
     * Snapshot-typed GET — reads the value from the in-process cache
     * without encoding / parsing RESP. Falls back to [get] on a
     * snapshot miss. Same rationale as [HashKey.getAllDirect]: Dazzle
     * is embedded, RESP is pure waste inside the SDK.
     *
     * Only the simple `SET key value` form (no EX/PX/XX/NX) hits the
     * snapshot — richer SET flavours fall through to the pipe.
     */
    fun getDirect(): String? = server.directGetString(key) ?: get()

    /** APPEND key value — returns the new total length. */
    fun append(value: String): Long =
        server.commandTyped("APPEND", key, value).asLongOrNull() ?: 0L

    /** STRLEN key — length in bytes, 0 if absent. */
    fun length(): Long =
        server.commandTyped("STRLEN", key).asLongOrNull() ?: 0L

    /** INCR key — atomic integer +1, creating the key as `0` first if absent. */
    fun incr(): Long =
        server.commandTyped("INCR", key).asLongOrNull() ?: 0L

    /** INCRBY key delta — atomic integer addition. */
    fun incrBy(delta: Long): Long =
        server.commandTyped("INCRBY", key, delta.toString()).asLongOrNull() ?: 0L

    /** INCRBYFLOAT key delta — atomic float addition. */
    fun incrByFloat(delta: Double): Double =
        server.commandTyped("INCRBYFLOAT", key, delta.toString())
            .asBulkOrNull()?.toDoubleOrNull() ?: 0.0

    /** DECR key — atomic integer -1. */
    fun decr(): Long =
        server.commandTyped("DECR", key).asLongOrNull() ?: 0L

    /** DECRBY key delta — atomic integer subtraction. */
    fun decrBy(delta: Long): Long =
        server.commandTyped("DECRBY", key, delta.toString()).asLongOrNull() ?: 0L

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}
