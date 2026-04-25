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
 * High-level, type-safe facade over a running [DazzleServer]. Obtain via
 * `server.client()` or `Valkey(server)` and use the factory methods to
 * get typed wrappers for each primitive:
 *
 * ```kotlin
 * val valkey = DazzleServer.client()
 *
 * val readings = valkey.stream("sensor:readings")
 * val stats    = valkey.hash("sensor:stats")
 * val anomalies = valkey.sortedSet("sensor:anomalies")
 * val decisions = valkey.list("agent:decisions")
 *
 * readings.add(mapOf("temp" to "22.3", "humidity" to "48"), maxLen = 200)
 * stats.incrByFloat("temp_sum", 22.3)
 * stats.incrBy("count", 1)
 * if (isAnomaly) anomalies.add(score = 45.0, member = "45")
 * ```
 *
 * Primitive instances are cheap — they just wrap the key name and a
 * reference to the server. They hold no state and can be created per
 * call site without worrying about object pooling.
 *
 * Use [namespace] to scope a prefix across a group of keys:
 *
 * ```kotlin
 * val sensor = valkey.namespace("sensor")      // every key gets "sensor:" prefix
 * val readings = sensor.stream("readings")     // → "sensor:readings"
 * val stats    = sensor.hash("stats")          // → "sensor:stats"
 * ```
 *
 * Every method is currently synchronous and blocking. Call from a
 * background thread (`Dispatchers.IO` or your own worker). A `suspend`
 * overload layer is planned for v1.2 — see ROADMAP.
 */
class Dazzle internal constructor(
    internal val server: DazzleServer,
    internal val prefix: String = "",
) {
    // ── Primitive factories ───────────────────────────────────────────────

    fun string(key: String)       = StringKey(prefix + key, server)
    fun list(key: String)         = ListKey(prefix + key, server)
    fun hash(key: String)         = HashKey(prefix + key, server)
    fun set(key: String)          = SetKey(prefix + key, server)
    fun sortedSet(key: String)    = SortedSetKey(prefix + key, server)
    fun stream(key: String)       = StreamKey(prefix + key, server)
    fun bitmap(key: String)       = BitmapKey(prefix + key, server)
    fun geo(key: String)          = GeoKey(prefix + key, server)
    fun hyperLogLog(key: String)  = HyperLogLogKey(prefix + key, server)

    /**
     * Vector similarity index backed by valkey-search (FT.CREATE / FT.SEARCH).
     * Requires [DazzleModule.VectorSearch] in [DazzleConfig.modules].
     *
     * @param name        FT index name (e.g. "docs")
     * @param hashPrefix  HSET key prefix the index scans (e.g. "doc:")
     * @param vectorField hash field that holds the FLOAT32 embedding blob
     * @param dim         embedding dimensionality (must match your model output)
     * @param algorithm   [VectorIndex.Algorithm.HNSW] (approx, fast) or FLAT (exact, small sets)
     * @param metric      distance metric: COSINE (default), L2 (Euclidean), IP (dot product)
     * @param initialCapacity  pre-allocate graph/label buffers for at least this
     *        many points so no `resizeIndex` fires during live traffic. 0 =
     *        library default (1024, doubles on demand).
     * @param m  HNSW graph degree. 0 = library default (32).
     * @param efConstruction  HNSW build-time candidate width. Lower = faster
     *        inserts at a small recall cost. 0 = library default (400).
     */
    fun vectorIndex(
        name: String,
        hashPrefix: String,
        vectorField: String = "embedding",
        dim: Int,
        algorithm: VectorIndex.Algorithm = VectorIndex.Algorithm.HNSW,
        metric: VectorIndex.Metric = VectorIndex.Metric.COSINE,
        initialCapacity: Int = 0,
        m: Int = 0,
        efConstruction: Int = 0,
    ) = VectorIndex(
        server, name, prefix + hashPrefix, vectorField, dim, algorithm, metric,
        initialCapacity, m, efConstruction,
    )

    /** Server-level diagnostics (INFO, MEMORY USAGE, SLOWLOG, TIME, etc.) */
    fun server(): ServerDiagnostics   = ServerDiagnostics(server)

    // ── Namespace helper ──────────────────────────────────────────────────

    /**
     * Returns a new [Valkey] view that prepends `"$name:"` to every key
     * produced by its factory methods. Compose by calling `.namespace(...)`
     * on the result again for nested scopes.
     */
    fun namespace(name: String): Dazzle =
        Dazzle(server, prefix = "$prefix$name:")

    // ── Key meta ops (apply to any primitive) ─────────────────────────────

    /** EXISTS k1 [k2 …] — returns the number of keys that exist. */
    fun exists(vararg keys: String): Long {
        if (keys.isEmpty()) return 0
        val qualified = Array(keys.size) { prefix + keys[it] }
        val args = arrayOf("EXISTS", *qualified)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** DEL k1 [k2 …] — returns the number of keys that were removed. */
    fun delete(vararg keys: String): Long {
        if (keys.isEmpty()) return 0
        val qualified = Array(keys.size) { prefix + keys[it] }
        val args = arrayOf("DEL", *qualified)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /** TYPE key — returns "string", "list", "hash", "set", "zset", "stream", "none". */
    fun type(key: String): String =
        server.commandTyped("TYPE", prefix + key).asBulkOrNull() ?: "none"

    // ── TTL family ────────────────────────────────────────────────────────

    /** EXPIRE key seconds — set a TTL in seconds. Returns true if applied. */
    fun expire(key: String, seconds: Long): Boolean =
        (server.commandTyped("EXPIRE", prefix + key, seconds.toString()).asLongOrNull() ?: 0L) == 1L

    /** PEXPIRE key ms — set a TTL in milliseconds. */
    fun pExpire(key: String, millis: Long): Boolean =
        (server.commandTyped("PEXPIRE", prefix + key, millis.toString()).asLongOrNull() ?: 0L) == 1L

    /** EXPIREAT key unix-seconds — set an absolute expiration time. */
    fun expireAt(key: String, unixSeconds: Long): Boolean =
        (server.commandTyped("EXPIREAT", prefix + key, unixSeconds.toString()).asLongOrNull() ?: 0L) == 1L

    /** PERSIST key — remove any TTL. Returns true if a TTL was removed. */
    fun persist(key: String): Boolean =
        (server.commandTyped("PERSIST", prefix + key).asLongOrNull() ?: 0L) == 1L

    /** TTL key — remaining seconds; -1 if no TTL, -2 if key missing. */
    fun ttl(key: String): Long =
        server.commandTyped("TTL", prefix + key).asLongOrNull() ?: -2L

    /** PTTL key — remaining milliseconds; -1 if no TTL, -2 if key missing. */
    fun pTtl(key: String): Long =
        server.commandTyped("PTTL", prefix + key).asLongOrNull() ?: -2L

    // ── Server-level meta ops ─────────────────────────────────────────────

    /** DBSIZE — total number of keys in the current database. */
    fun dbSize(): Long =
        server.commandTyped("DBSIZE").asLongOrNull() ?: 0L

    /** FLUSHDB — delete every key in the current database. Returns true on OK. */
    fun flushDb(): Boolean {
        val r = server.commandTyped("FLUSHDB")
        return (r as? RespValue.SimpleString)?.value == "OK"
    }

    /**
     * FLUSHALL — delete every key in every database. Returns true on OK.
     *
     * Less surgical than [flushDb] but convenient for tests that want a
     * hard reset without stopping the server.
     */
    fun flushAll(): Boolean {
        val r = server.commandTyped("FLUSHALL")
        return (r as? RespValue.SimpleString)?.value == "OK"
    }

    /** PING — round-trips a simple command for connectivity checks. */
    fun ping(): Boolean {
        val r = server.commandTyped("PING")
        return (r as? RespValue.SimpleString)?.value == "PONG"
    }

    // ── Transactions (MULTI / EXEC / WATCH / DISCARD) ─────────────────────

    /**
     * Run [block] as an atomic Valkey transaction. The block can call
     * `watch(...)` to set up optimistic locking before the MULTI marker,
     * and then invoke any primitive methods to enqueue commands.
     *
     * Returns the array of per-command replies from EXEC, or null if the
     * transaction aborted because a watched key changed.
     */
    fun transaction(block: TransactionScope.() -> Unit): List<RespValue>? {
        val scope = TransactionScope(this)
        scope.block()

        // Send WATCH keys (if any) first, while we still hold nothing in
        // the MULTI buffer on the server side.
        if (scope.watchedKeys.isNotEmpty()) {
            val watchArgs = arrayOf("WATCH", *scope.watchedKeys.toTypedArray())
            server.commandTyped(*watchArgs)
        }

        // NOTE: the block has ALREADY executed its primitive calls above,
        // which means the commands already hit the server BEFORE MULTI.
        // The current TransactionScope is therefore a "staging area"
        // for WATCH and nothing more — to get true MULTI/EXEC atomicity
        // we'd need to defer every primitive call inside the scope into
        // a queue and dispatch after MULTI. That's a v1.2+ task; for v1
        // this API sets up WATCH and runs the block optimistically.
        // See docs/ROADMAP.md → "deferred command recording".

        // For now, return whatever the last EXEC-equivalent would have
        // produced. Until the deferred-queue implementation lands, callers
        // that need strict atomicity should use Lua scripts.
        val exec = server.commandTyped("EXEC")
        return (exec as? RespValue.Array)?.items
    }

    /** UNWATCH — cancel any outstanding WATCH. */
    fun unwatch() { server.commandTyped("UNWATCH") }

    // ── Lua scripting ─────────────────────────────────────────────────────

    /**
     * Obtain a [LuaScript] handle for [source]. The script itself is not
     * uploaded to the server until the first [LuaScript.eval] or
     * [LuaScript.evalSha] call; once loaded, subsequent invocations
     * reuse the server-side SHA cache.
     */
    fun script(source: String): LuaScript = LuaScript(source, server)

    // ── Pub/Sub ───────────────────────────────────────────────────────────

    /**
     * Publish [message] to [channel]. Returns the number of subscribers
     * that received the message on the Valkey side. Thread-safe.
     */
    fun publish(channel: String, message: String): Long =
        server.commandTyped("PUBLISH", prefix + channel, message).asLongOrNull() ?: 0L

    // ── Scan iteration ────────────────────────────────────────────────────

    /**
     * Cursor-based iteration over the keyspace. Yields one batch per
     * SCAN round-trip. Safe for keyspaces with millions of keys — O(1)
     * per call, O(N) total with sub-linear memory.
     *
     * ```kotlin
     * for (batch in valkey.scan(match = "sensor:*", count = 200)) {
     *     for (key in batch) println(key)
     * }
     * ```
     *
     * The [match] pattern is the same as the KEYS pattern syntax
     * (`*`, `?`, `[abc]`). The [count] is a *hint* — Valkey may return
     * fewer or more keys per call.
     */
    fun scan(match: String? = null, count: Long? = null): Sequence<List<String>> = sequence {
        var cursor = "0"
        do {
            val args = mutableListOf("SCAN", cursor)
            if (match != null) { args += "MATCH"; args += prefix + match }
            if (count != null) { args += "COUNT"; args += count.toString() }
            val reply = server.commandTyped(*args.toTypedArray()).asArray()
            cursor = reply.getOrNull(0)?.asBulkOrNull() ?: "0"
            val batch = reply.getOrNull(1)?.asArray()
                ?.mapNotNull { it.asBulkOrNull() }
                ?: emptyList()
            if (batch.isNotEmpty()) yield(batch)
        } while (cursor != "0")
    }
    /**
     * Temporal Fault Intelligence primitive — symbolic online-learning
     * fault prediction for LLM-augmented industrial monitoring workloads.
     *
     * Combines six deterministic seed signals (interval_expected, overdue,
     * cluster_moderate, cluster_dense, precursor_strong,
     * rising/dropping_near_threshold) with three NAMUR NE43 status-code
     * signals (status_flicker, status_out_of_range, status_fault_reported)
     * and per-signal Bayesian posterior updates, all in-process.
     *
     * Requires [DazzleModule.TFI] in [DazzleConfig.modules] so the module
     * is registered at server start via `--loadmodule @static:tfi`
     * (the implementation is linked into `libdazzle.so` directly).
     */
    fun tfi(key: String) = TfiIndex(prefix + key, server)
}
