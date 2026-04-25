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
 * Type-safe wrapper around a Valkey sorted set. Obtain via
 * `valkey.sortedSet("key")`.
 *
 * Sorted sets are a map of unique members to floating-point scores, kept
 * ordered by score. Valkey exposes range queries on the score — the
 * operation our sensor pipeline needs for "all anomaly minutes between
 * X and Y".
 *
 * ```kotlin
 * val anomalies = valkey.sortedSet("sensor:anomalies")
 *
 * anomalies.add(score = 45.0, member = "45")
 * anomalies.add(score = 94.0, member = "94")
 *
 * val recent = anomalies.rangeByScore(min = 40.0, max = 100.0)  // ["45", "94"]
 * val withScores = anomalies.rangeByScoreWithScores(min = 0.0, max = 200.0)
 * ```
 */
class SortedSetKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {
    /** A member with its score. Used by `*WithScores` variants. */
    data class ScoredMember(val member: String, val score: Double)

    /** ZADD key score member — returns true if the member is new. */
    fun add(score: Double, member: String): Boolean {
        val n = server.commandTyped("ZADD", key, score.toString(), member).asLongOrNull() ?: 0L
        return n == 1L
    }

    /** ZADD key s1 m1 s2 m2 … — returns the number of *new* members added. */
    fun addAll(members: Map<String, Double>): Long {
        if (members.isEmpty()) return 0L
        val args = mutableListOf("ZADD", key)
        for ((m, s) in members) { args += s.toString(); args += m }
        return server.commandTyped(*args.toTypedArray()).asLongOrNull() ?: 0L
    }

    /** ZSCORE key member — null if member is not present. */
    fun score(member: String): Double? =
        server.commandTyped("ZSCORE", key, member).asBulkOrNull()?.toDoubleOrNull()

    /** ZRANK key member — zero-based ascending rank, null if absent. */
    fun rank(member: String): Long? =
        server.commandTyped("ZRANK", key, member).asLongOrNull()

    /** ZREVRANK key member — zero-based descending rank, null if absent. */
    fun revRank(member: String): Long? =
        server.commandTyped("ZREVRANK", key, member).asLongOrNull()

    /** ZRANGE key start stop — indices are inclusive, negative wraps from the end. */
    fun range(start: Long, stop: Long): List<String> =
        server.commandTyped("ZRANGE", key, start.toString(), stop.toString())
            .asArray()
            .mapNotNull { it.asBulkOrNull() }

    /** ZRANGE key start stop WITHSCORES */
    fun rangeWithScores(start: Long, stop: Long): List<ScoredMember> {
        val raw = server.commandTyped("ZRANGE", key, start.toString(), stop.toString(), "WITHSCORES")
        return decodeScoredPairs(raw)
    }

    /**
     * ZRANGEBYSCORE key min max [LIMIT offset count]
     *
     * Both bounds are inclusive. Use `Double.NEGATIVE_INFINITY` /
     * `Double.POSITIVE_INFINITY` for open bounds (they serialize to
     * "-inf" / "+inf" which Valkey understands).
     */
    fun rangeByScore(min: Double, max: Double, limit: LongRange? = null): List<String> {
        val args = mutableListOf("ZRANGEBYSCORE", key, formatScore(min), formatScore(max))
        if (limit != null) {
            args += "LIMIT"
            args += limit.first.toString()
            args += (limit.last - limit.first + 1).toString()
        }
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .mapNotNull { it.asBulkOrNull() }
    }

    /**
     * Snapshot-typed ZRANGEBYSCORE — returns members whose stored score
     * lies in `[min, max]` (inclusive) sorted ascending by score.
     *
     * Falls back to [rangeByScore] on a snapshot miss, so callers can
     * invoke unconditionally. Drops ~80-150 µs per call vs the RESP
     * path when the time index is hot.
     *
     * Limitation: this fast path ignores the `limit` parameter (the
     * snapshot caps each zset at 64 members already). Callers that need
     * pagination should use the pipe-path [rangeByScore]. Dropping
     * members silently would violate the contract, so we keep the fast
     * path strictly for the "give me every id in range" query that
     * ContextStore.byTimeRange actually uses.
     */
    fun rangeByScoreDirect(min: Double, max: Double): List<String> {
        val arr = server.directZrangeByScore(key, min, max) ?: return rangeByScore(min, max)
        return arr.filterNotNull()
    }

    /** ZRANGEBYSCORE key min max WITHSCORES [LIMIT offset count] */
    fun rangeByScoreWithScores(
        min: Double,
        max: Double,
        limit: LongRange? = null,
    ): List<ScoredMember> {
        val args = mutableListOf("ZRANGEBYSCORE", key, formatScore(min), formatScore(max), "WITHSCORES")
        if (limit != null) {
            args += "LIMIT"
            args += limit.first.toString()
            args += (limit.last - limit.first + 1).toString()
        }
        return decodeScoredPairs(server.commandTyped(*args.toTypedArray()))
    }

    /** ZREM key m1 [m2 …] — returns number of members actually removed. */
    fun remove(vararg members: String): Long {
        if (members.isEmpty()) return 0L
        val args = arrayOf("ZREM", key, *members)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** ZREMRANGEBYSCORE — removes every member with score in [min, max]. */
    fun removeRangeByScore(min: Double, max: Double): Long =
        server.commandTyped("ZREMRANGEBYSCORE", key, formatScore(min), formatScore(max))
            .asLongOrNull() ?: 0L

    /** ZCARD — total number of members. */
    fun cardinality(): Long =
        server.commandTyped("ZCARD", key).asLongOrNull() ?: 0L

    /** ZCOUNT key min max — count of members with score in the range. */
    fun count(min: Double, max: Double): Long =
        server.commandTyped("ZCOUNT", key, formatScore(min), formatScore(max))
            .asLongOrNull() ?: 0L

    /** ZINCRBY key delta member — atomic score update, returns post-update score. */
    fun incrBy(member: String, delta: Double): Double {
        val r = server.commandTyped("ZINCRBY", key, delta.toString(), member)
        return r.asBulkOrNull()?.toDoubleOrNull() ?: 0.0
    }

    /** ZSCAN cursor iteration over (member, score) pairs, batch per round-trip. */
    fun scan(match: String? = null, count: Long? = null): Sequence<List<ScoredMember>> = sequence {
        var cursor = "0"
        do {
            val args = mutableListOf("ZSCAN", key, cursor)
            if (match != null) { args += "MATCH"; args += match }
            if (count != null) { args += "COUNT"; args += count.toString() }
            val reply = server.commandTyped(*args.toTypedArray()).asArray()
            cursor = reply.getOrNull(0)?.asBulkOrNull() ?: "0"
            val items = reply.getOrNull(1)?.asArray() ?: emptyList()
            val batch = mutableListOf<ScoredMember>()
            var i = 0
            while (i < items.size - 1) {
                val m = items[i].asBulkOrNull() ?: ""
                val s = items[i + 1].asBulkOrNull()?.toDoubleOrNull() ?: 0.0
                batch += ScoredMember(member = m, score = s)
                i += 2
            }
            if (batch.isNotEmpty()) yield(batch)
        } while (cursor != "0")
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L

    // ── Helpers ───────────────────────────────────────────────────────────

    private fun formatScore(s: Double): String = when {
        s == Double.POSITIVE_INFINITY -> "+inf"
        s == Double.NEGATIVE_INFINITY -> "-inf"
        else -> s.toString()
    }

    private fun decodeScoredPairs(reply: RespValue): List<ScoredMember> {
        val items = reply.asArray()
        val out = ArrayList<ScoredMember>(items.size / 2)
        var i = 0
        while (i < items.size - 1) {
            val member = items[i].asBulkOrNull() ?: ""
            val score = items[i + 1].asBulkOrNull()?.toDoubleOrNull() ?: 0.0
            out += ScoredMember(member = member, score = score)
            i += 2
        }
        return out
    }
}
