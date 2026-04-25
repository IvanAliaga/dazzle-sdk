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
 * Type-safe wrapper around a Valkey HyperLogLog. Obtain via
 * `valkey.hyperLogLog("key")`.
 *
 * HyperLogLog is a probabilistic cardinality estimator: it answers
 * "how many unique items have I seen?" with ~0.81% error and a fixed
 * footprint of roughly 12 KB, regardless of whether you inserted 10
 * items or 10 million. Perfect for edge use cases like "how many
 * unique sensor IDs reported today" or "how many unique anomaly
 * minutes observed this week" without storing the actual set.
 *
 * ```kotlin
 * val uniqueDevices = valkey.hyperLogLog("devices:seen:today")
 *
 * uniqueDevices.add("sensor-42", "sensor-101", "sensor-999")
 * val estimatedUnique = uniqueDevices.count()    // ~= 3
 * ```
 *
 * Use [merge] to combine multiple HLL keys into one (e.g., union the
 * last 7 days into a 7-day total without double-counting).
 */
class HyperLogLogKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {

    /**
     * PFADD key e1 [e2 …] — adds elements to the HLL. Returns true if
     * the internal register was modified (i.e., the estimate changed).
     */
    fun add(vararg elements: String): Boolean {
        if (elements.isEmpty()) return false
        val args = arrayOf("PFADD", key, *elements)
        return (server.commandTyped(*args).asLongOrNull() ?: 0L) == 1L
    }

    /** PFCOUNT key — estimated unique cardinality. */
    fun count(): Long =
        server.commandTyped("PFCOUNT", key).asLongOrNull() ?: 0L

    /**
     * PFCOUNT k1 k2 … — estimated cardinality of the UNION of multiple HLL keys.
     * Does not mutate any of the source keys.
     */
    fun unionCount(vararg otherKeys: String): Long {
        val args = arrayOf("PFCOUNT", key, *otherKeys)
        return server.commandTyped(*args).asLongOrNull() ?: 0L
    }

    /**
     * PFMERGE destkey k1 k2 … — merges the union of the given keys into [key].
     * [key] is the destination; [sources] are added to it. Returns true on OK.
     */
    fun merge(vararg sources: String): Boolean {
        if (sources.isEmpty()) return false
        val args = arrayOf("PFMERGE", key, *sources)
        val r = server.commandTyped(*args)
        return (r as? RespValue.SimpleString)?.value == "OK"
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}
