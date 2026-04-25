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
 * Typed view of Valkey `INFO` output. Obtain via [Valkey.server].info().
 *
 * `INFO` returns a flat text block like:
 *
 *     # Server
 *     redis_version:255.255.255
 *     ...
 *     # Clients
 *     connected_clients:1
 *     ...
 *     # Memory
 *     used_memory:1234567
 *     ...
 *
 * [ServerInfo] parses that into a map-of-maps indexed by section name.
 * The most common metrics have direct accessors ([usedMemoryBytes],
 * [connectedClients], [totalCommandsProcessed]…) that handle the
 * type coercion.
 *
 * Unknown keys remain in [rawSections] for callers that want to read
 * them without a dedicated accessor.
 */
data class ServerInfo(
    /** Parsed sections: section name → field → value. */
    val rawSections: Map<String, Map<String, String>>,
) {
    // ── Common fields (typed, with fallbacks) ─────────────────────────────

    val redisVersion: String? get() = field("Server", "redis_version")
    val uptimeSeconds: Long? get() = field("Server", "uptime_in_seconds")?.toLongOrNull()
    val processId: Long? get() = field("Server", "process_id")?.toLongOrNull()

    val connectedClients: Long? get() = field("Clients", "connected_clients")?.toLongOrNull()

    val usedMemoryBytes: Long? get() = field("Memory", "used_memory")?.toLongOrNull()
    val usedMemoryHuman: String? get() = field("Memory", "used_memory_human")
    val maxMemoryBytes: Long? get() = field("Memory", "maxmemory")?.toLongOrNull()

    val totalCommandsProcessed: Long? get() = field("Stats", "total_commands_processed")?.toLongOrNull()
    val instantaneousOpsPerSec: Long? get() = field("Stats", "instantaneous_ops_per_sec")?.toLongOrNull()
    val keyspaceHits: Long? get() = field("Stats", "keyspace_hits")?.toLongOrNull()
    val keyspaceMisses: Long? get() = field("Stats", "keyspace_misses")?.toLongOrNull()

    val aofEnabled: Boolean? get() = field("Persistence", "aof_enabled")?.let { it == "1" }
    val rdbLastSaveTime: Long? get() = field("Persistence", "rdb_last_save_time")?.toLongOrNull()

    fun field(section: String, name: String): String? = rawSections[section]?.get(name)

    companion object {
        /** Parse the raw text output of `INFO` into a [ServerInfo]. */
        fun parse(raw: String): ServerInfo {
            val sections = linkedMapOf<String, MutableMap<String, String>>()
            var current = ""
            raw.lineSequence().forEach { line ->
                val trimmed = line.trim()
                when {
                    trimmed.isEmpty() -> { /* skip */ }
                    trimmed.startsWith("#") -> {
                        current = trimmed.removePrefix("#").trim()
                        sections.getOrPut(current) { linkedMapOf() }
                    }
                    ':' in trimmed -> {
                        val idx = trimmed.indexOf(':')
                        val k = trimmed.substring(0, idx)
                        val v = trimmed.substring(idx + 1)
                        sections.getOrPut(current) { linkedMapOf() }[k] = v
                    }
                }
            }
            return ServerInfo(sections.mapValues { it.value.toMap() })
        }
    }
}

/**
 * Entry point for server-level diagnostic operations. Obtain via
 * `valkey.server()`.
 *
 * Methods here are intentionally grouped together because they don't
 * operate on a specific key — they're observability primitives that
 * return state about the Valkey instance itself.
 */
class ServerDiagnostics internal constructor(private val server: DazzleServer) {

    // ── INFO ──────────────────────────────────────────────────────────────

    /** INFO [section] — typed view of the Valkey info dump. */
    fun info(section: String? = null): ServerInfo {
        val raw = if (section != null) {
            server.commandTyped("INFO", section)
        } else {
            server.commandTyped("INFO")
        }
        return ServerInfo.parse(raw.asBulkOrNull() ?: "")
    }

    // ── Memory / diagnostics ──────────────────────────────────────────────

    /** MEMORY USAGE key — approximate bytes consumed by a single key. */
    fun memoryUsage(key: String): Long? =
        server.commandTyped("MEMORY", "USAGE", key).asLongOrNull()

    /** DEBUG SLEEP seconds — used by tests to simulate a busy server. */
    fun debugSleep(seconds: Double) {
        server.commandTyped("DEBUG", "SLEEP", seconds.toString())
    }

    // ── Slow log ──────────────────────────────────────────────────────────

    data class SlowLogEntry(
        val id: Long,
        val timestampUnixSeconds: Long,
        val durationMicros: Long,
        val args: List<String>,
    )

    /** SLOWLOG GET [count] — retrieve recent slow commands. */
    fun slowLog(count: Int = 10): List<SlowLogEntry> {
        val items = server.commandTyped("SLOWLOG", "GET", count.toString()).asArray()
        return items.mapNotNull { row ->
            val arr = row.asArray()
            if (arr.size < 4) return@mapNotNull null
            SlowLogEntry(
                id                   = arr[0].asLongOrNull() ?: return@mapNotNull null,
                timestampUnixSeconds = arr[1].asLongOrNull() ?: return@mapNotNull null,
                durationMicros       = arr[2].asLongOrNull() ?: return@mapNotNull null,
                args                 = arr[3].asArray().mapNotNull { it.asBulkOrNull() },
            )
        }
    }

    /** SLOWLOG RESET — clear the slow-log buffer. */
    fun slowLogReset() { server.commandTyped("SLOWLOG", "RESET") }

    // ── Persistence ───────────────────────────────────────────────────────

    /** BGSAVE — start an async RDB snapshot. Returns true on +OK. */
    fun bgSave(): Boolean {
        val r = server.commandTyped("BGSAVE")
        return (r as? RespValue.SimpleString)?.value?.startsWith("Background") == true
            || (r as? RespValue.SimpleString)?.value == "OK"
    }

    /** LASTSAVE — unix timestamp of the last successful RDB save. */
    fun lastSaveTime(): Long = server.commandTyped("LASTSAVE").asLongOrNull() ?: 0L

    // ── Time ──────────────────────────────────────────────────────────────

    /** TIME — server's notion of the current time as a (unix-seconds, microseconds) pair. */
    fun time(): Pair<Long, Long> {
        val r = server.commandTyped("TIME").asArray()
        val s = r.getOrNull(0)?.asBulkOrNull()?.toLongOrNull() ?: 0L
        val us = r.getOrNull(1)?.asBulkOrNull()?.toLongOrNull() ?: 0L
        return s to us
    }
}
