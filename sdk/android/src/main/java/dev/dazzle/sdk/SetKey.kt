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
 * Type-safe wrapper around a Valkey set (unordered, unique members).
 * Obtain via `valkey.set("key")`.
 *
 * Use when you need fast O(1) add / remove / exists checks and don't
 * care about order or scores. For scored sets see [SortedSetKey].
 *
 * ```kotlin
 * val seen = valkey.set("users:seen-today")
 *
 * seen.add("alice", "bob", "carol")
 * val isMember = seen.contains("alice")   // true
 * val size = seen.cardinality()
 * val all = seen.members()                // Set<String>
 * ```
 */
class SetKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {

    /** SADD key m1 [m2 …] — returns the number of new members added. */
    fun add(vararg members: String): Long {
        if (members.isEmpty()) return 0L
        val args = arrayOf("SADD", key, *members)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** SREM key m1 [m2 …] — returns the number of members actually removed. */
    fun remove(vararg members: String): Long {
        if (members.isEmpty()) return 0L
        val args = arrayOf("SREM", key, *members)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** SISMEMBER key member */
    fun contains(member: String): Boolean =
        (server.commandTyped("SISMEMBER", key, member).asLongOrNull() ?: 0L) == 1L

    /** SMEMBERS key — every member as a Set<String>. */
    fun members(): Set<String> =
        server.commandTyped("SMEMBERS", key)
            .asArray()
            .mapNotNull { it.asBulkOrNull() }
            .toSet()

    /**
     * Snapshot-typed SMEMBERS — same result as [members] but reads from
     * the in-process snapshot cache without encoding or parsing RESP.
     * Drops ~60-100 µs per call on records hot in the cache. Falls back
     * to [members] on a snapshot miss, so callers can invoke this
     * unconditionally — the fast path is a pure win.
     *
     * Used by [DazzleContextStore.byTag] / byTags to iterate tag
     * indexes without the RESP round-trip. Same rationale as
     * HashKey.getAllDirect: Dazzle is embedded, nobody outside the SDK
     * ever consumes that RESP string.
     */
    fun membersDirect(): Set<String> {
        val arr = server.directSmembers(key) ?: return members()
        val out = LinkedHashSet<String>(arr.size)
        for (m in arr) { if (m != null) out.add(m) }
        return out
    }

    /** SCARD key — number of members. */
    fun cardinality(): Long =
        server.commandTyped("SCARD", key).asLongOrNull() ?: 0L

    /** SPOP key [count] — remove and return a random member. */
    fun pop(): String? =
        server.commandTyped("SPOP", key).asBulkOrNull()

    /** SRANDMEMBER key [count] — return (but do not remove) a random member. */
    fun randomMember(): String? =
        server.commandTyped("SRANDMEMBER", key).asBulkOrNull()

    /** SSCAN cursor iteration over set members, batch per round-trip. */
    fun scan(match: String? = null, count: Long? = null): Sequence<List<String>> = sequence {
        var cursor = "0"
        do {
            val args = mutableListOf("SSCAN", key, cursor)
            if (match != null) { args += "MATCH"; args += match }
            if (count != null) { args += "COUNT"; args += count.toString() }
            val reply = server.commandTyped(*args.toTypedArray()).asArray()
            cursor = reply.getOrNull(0)?.asBulkOrNull() ?: "0"
            val batch = reply.getOrNull(1)?.asArray()
                ?.mapNotNull { it.asBulkOrNull() }
                ?: emptyList()
            if (batch.isNotEmpty()) yield(batch)
        } while (cursor != "0")
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}
