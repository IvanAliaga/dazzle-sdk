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
 * Type-safe wrapper around a Valkey hash. Obtain via `valkey.hash("key")`.
 *
 * Covers the full HSET / HGET / HGETALL / HINCRBY family plus HDEL, HEXISTS,
 * HKEYS, HVALS, HLEN. Every method issues exactly one Valkey command and
 * returns an already-decoded Kotlin type — no RESP or string parsing on
 * the consumer side.
 *
 * ```kotlin
 * val stats = valkey.hash("sensor:stats")
 *
 * stats.incrByFloat("temp_sum", 22.3)
 * stats.incrBy("count", 1)
 * val count = stats.get("count")?.toIntOrNull() ?: 0
 * val all   = stats.getAll()  // Map<String, String>
 * ```
 */
class HashKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {

    /**
     * HSET key field value
     *
     * @return true if the field is new, false if it already existed.
     */
    fun set(field: String, value: String): Boolean {
        val r = server.commandTyped("HSET", key, field, value)
        return (r.asLongOrNull() ?: 0L) == 1L
    }

    /**
     * HSET key f1 v1 f2 v2 …
     *
     * @return number of newly added (previously non-existent) fields.
     */
    fun setAll(pairs: Map<String, String>): Long {
        if (pairs.isEmpty()) return 0L
        val args = mutableListOf("HSET", key)
        for ((k, v) in pairs) { args += k; args += v }
        return server.commandTyped(*args.toTypedArray()).asLongOrNull() ?: 0L
    }

    /** HGET key field — null if the field does not exist. */
    fun get(field: String): String? =
        server.commandTyped("HGET", key, field).asBulkOrNull()

    /** HMGET key f1 f2 … — null for fields that do not exist. */
    fun mGet(vararg fields: String): List<String?> {
        if (fields.isEmpty()) return emptyList()
        val args = arrayOf("HMGET", key, *fields)
        return server.commandTyped(*args)
            .asArray()
            .map { it.asBulkOrNull() }
    }

    /**
     * Like [mGet] but uses the in-process snapshot cache (Phase 1 bypass),
     * skipping the event-loop pipe entirely.
     *
     * The return protocol is controlled by [DazzleConfig.directReadProtocol]:
     *
     * - **TYPED** *(default)*: reads `String?[]` directly from the C snapshot
     *   via `nativeDirectReadFields` — no RESP serialisation at any layer.
     *   Fastest path (~50 µs). Null elements indicate absent fields.
     *
     * - **RESP**: serialises snapshot values to a RESP2 bulk array in C, then
     *   decodes in Kotlin with [RespParser]. Same semantics as a standard
     *   Valkey HMGET response. Use this when migrating from Jedis/Lettuce or
     *   when RESP3 compatibility is required.
     *
     * Falls back to [mGet] (pipe path) if the key is not yet in the snapshot.
     */
    fun mGetDirect(vararg fields: String): List<String?> {
        if (fields.isEmpty()) return emptyList()

        return when (server.config.directReadProtocol) {

            DirectReadProtocol.TYPED -> {
                // Phase 5: typed String?[] — no RESP at any layer
                @Suppress("UNCHECKED_CAST")
                val typed = server.directReadFields(key, *fields)
                if (typed != null) typed.toList()
                else mGet(*fields)   // key not yet in snapshot → pipe fallback
            }

            DirectReadProtocol.RESP -> {
                // Phase 1 RESP path — snapshot → snprintf → RESP string → parse
                val args = arrayOf("HMGET", key, *fields)
                val raw = server.directRead(*args) ?: return mGet(*fields)
                RespParser.parse(raw).asArray().map { it.asBulkOrNull() }
            }
        }
    }

    /**
     * Single-field typed fast path. Reads exactly one field through
     * `nativeDirectReadField`, skipping the vararg + array allocation of
     * [mGetDirect]. Returns null on snapshot miss OR when the field is
     * absent — use [mGetDirect] when you need to tell the two apart.
     *
     * Ideal for materialised-view reads that consume a single precomputed
     * blob (e.g. Precompute v2's `ctx_block`).
     */
    fun getDirect(field: String): String? =
        server.directReadField(key, field)
            ?: get(field)   // snapshot miss → pipe fallback to HGET

    /** HGETALL key — every field/value pair in the hash. */
    /**
     * Snapshot-typed HGETALL — reads every (field, value) pair for this
     * hash without encoding / parsing RESP. Drops ~50-80 µs per call vs
     * [getAll] on records already hot in the snapshot cache.
     *
     * Falls back to [getAll] on a snapshot miss, so the fast path is a
     * pure win: consumers call this unconditionally and the pipe path is
     * only paid on records that haven't been written since the last cache
     * flush.
     *
     * Used by [DazzleContextStore.get] to recover the pre-refactor
     * performance lead over ObjectBox / SQLite-AI that regressed when the
     * ContextStore was switched to the generic RESP path.
     */
    fun getAllDirect(): Map<String, String> {
        val flat = server.directHgetall(key)
        if (flat == null) return getAll()
        val out = LinkedHashMap<String, String>(flat.size / 2)
        var i = 0
        while (i + 1 < flat.size) {
            val k = flat[i]
            val v = flat[i + 1]
            if (k != null && v != null) out[k] = v
            i += 2
        }
        return out
    }

    fun getAll(): Map<String, String> {
        val items = server.commandTyped("HGETALL", key).asArray()
        val out = linkedMapOf<String, String>()
        var i = 0
        while (i < items.size - 1) {
            val k = items[i].asBulkOrNull() ?: ""
            val v = items[i + 1].asBulkOrNull() ?: ""
            out[k] = v
            i += 2
        }
        return out
    }

    /** HDEL key f1 [f2 …] — returns the number of fields removed. */
    fun delete(vararg fields: String): Long {
        if (fields.isEmpty()) return 0L
        val args = arrayOf("HDEL", key, *fields)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** HEXISTS key field */
    fun exists(field: String): Boolean =
        (server.commandTyped("HEXISTS", key, field).asLongOrNull() ?: 0L) == 1L

    /** HLEN key — number of fields. */
    fun length(): Long =
        server.commandTyped("HLEN", key).asLongOrNull() ?: 0L

    /** HKEYS key — all field names. */
    fun keys(): List<String> =
        server.commandTyped("HKEYS", key)
            .asArray()
            .mapNotNull { it.asBulkOrNull() }

    /** HVALS key — all values. */
    fun values(): List<String> =
        server.commandTyped("HVALS", key)
            .asArray()
            .mapNotNull { it.asBulkOrNull() }

    /**
     * HSCAN cursor iteration. Yields one batch of (field, value) pairs
     * per round-trip. Safe for huge hashes — sub-linear memory.
     */
    fun scan(match: String? = null, count: Long? = null): Sequence<Map<String, String>> = sequence {
        var cursor = "0"
        do {
            val args = mutableListOf("HSCAN", key, cursor)
            if (match != null) { args += "MATCH"; args += match }
            if (count != null) { args += "COUNT"; args += count.toString() }
            val reply = server.commandTyped(*args.toTypedArray()).asArray()
            cursor = reply.getOrNull(0)?.asBulkOrNull() ?: "0"
            val pairs = reply.getOrNull(1)?.asArray() ?: emptyList()
            val batch = linkedMapOf<String, String>()
            var i = 0
            while (i < pairs.size - 1) {
                val f = pairs[i].asBulkOrNull() ?: ""
                val v = pairs[i + 1].asBulkOrNull() ?: ""
                batch[f] = v
                i += 2
            }
            if (batch.isNotEmpty()) yield(batch)
        } while (cursor != "0")
    }

    // ── Atomic numeric ops ────────────────────────────────────────────────

    /**
     * HINCRBY key field delta — atomically adds [delta] to the integer
     * value at [field]. Creates the field as `0` first if it did not
     * exist. Returns the post-increment value.
     */
    fun incrBy(field: String, delta: Long): Long =
        server.commandTyped("HINCRBY", key, field, delta.toString()).asLongOrNull() ?: 0L

    /**
     * HINCRBYFLOAT key field delta — atomic float addition. Created as
     * `0.0` if absent. Returns the post-increment value.
     */
    fun incrByFloat(field: String, delta: Double): Double {
        val raw = server.commandTyped("HINCRBYFLOAT", key, field, delta.toString())
        return raw.asBulkOrNull()?.toDoubleOrNull() ?: 0.0
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    /** DEL — delete the entire hash. Returns true if the hash existed. */
    fun delete(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    /** EXISTS key — whether the hash exists at all. */
    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L

    // ─────────────────────────────────────────────────────────────────────
    // Hash Field Expiration — Valkey 8 first-class feature
    //
    // Each field inside a hash can carry its own TTL, completely
    // independently from the hash key's own TTL. This is **the** Valkey-8
    // capability that has no equivalent in SQLite or traditional KV stores:
    // a single hash can model "per-memory-entry expiration" in one primitive
    // instead of a table + index + CRON job + deletion policy.
    //
    // Useful patterns for LLM agents:
    //   - agent:memory where each field is a remembered fact with its own
    //     decay window
    //   - session:cache with per-entry revalidation windows
    //   - rate limiting counters where each tracked subject has its own
    //     window
    //
    // Returns semantics:
    //   - 1  — TTL applied successfully
    //   - 0  — field exists but condition (NX/XX/GT/LT) prevented change
    //   - -2 — field does not exist
    // ─────────────────────────────────────────────────────────────────────

    /** HEXPIRE key seconds FIELDS n f1 [f2 …] — set a TTL on each field. */
    fun expireField(field: String, seconds: Long): Int =
        expireFields(seconds, field).firstOrNull() ?: -2

    /** HEXPIRE applied to multiple fields in one call. Returns per-field result codes. */
    fun expireFields(seconds: Long, vararg fields: String): List<Int> {
        if (fields.isEmpty()) return emptyList()
        val args = mutableListOf("HEXPIRE", key, seconds.toString(), "FIELDS", fields.size.toString())
        args.addAll(fields)
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .map { (it.asLongOrNull() ?: -2L).toInt() }
    }

    /** HPEXPIRE — TTL in milliseconds. */
    fun pExpireField(field: String, millis: Long): Int =
        pExpireFields(millis, field).firstOrNull() ?: -2

    fun pExpireFields(millis: Long, vararg fields: String): List<Int> {
        if (fields.isEmpty()) return emptyList()
        val args = mutableListOf("HPEXPIRE", key, millis.toString(), "FIELDS", fields.size.toString())
        args.addAll(fields)
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .map { (it.asLongOrNull() ?: -2L).toInt() }
    }

    /** HEXPIREAT — absolute expiration time (unix seconds). */
    fun expireFieldAt(field: String, unixSeconds: Long): Int {
        val r = server.commandTyped(
            "HEXPIREAT", key, unixSeconds.toString(), "FIELDS", "1", field
        ).asArray()
        return (r.firstOrNull()?.asLongOrNull() ?: -2L).toInt()
    }

    /** HTTL — remaining seconds on each field. -1 if no TTL, -2 if absent. */
    fun ttlField(field: String): Long = ttlFields(field).firstOrNull() ?: -2L

    fun ttlFields(vararg fields: String): List<Long> {
        if (fields.isEmpty()) return emptyList()
        val args = mutableListOf("HTTL", key, "FIELDS", fields.size.toString())
        args.addAll(fields)
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .map { it.asLongOrNull() ?: -2L }
    }

    /** HPTTL — remaining milliseconds. */
    fun pTtlField(field: String): Long = pTtlFields(field).firstOrNull() ?: -2L

    fun pTtlFields(vararg fields: String): List<Long> {
        if (fields.isEmpty()) return emptyList()
        val args = mutableListOf("HPTTL", key, "FIELDS", fields.size.toString())
        args.addAll(fields)
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .map { it.asLongOrNull() ?: -2L }
    }

    /** HPERSIST — remove any per-field TTL. Returns true if a TTL was removed. */
    fun persistField(field: String): Boolean {
        val r = server.commandTyped("HPERSIST", key, "FIELDS", "1", field).asArray()
        return (r.firstOrNull()?.asLongOrNull() ?: -2L) == 1L
    }
}
