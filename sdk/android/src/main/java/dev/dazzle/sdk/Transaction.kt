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
 * Atomic transaction DSL — sends `MULTI` + the queued commands + `EXEC`
 * in one direct-dispatch batch. Every command inside the block is
 * guaranteed to run sequentially against the server without any
 * other client's commands interleaving.
 *
 * ```kotlin
 * valkey.transaction {
 *     hash("sensor:stats").incrBy("count", 1)
 *     hash("sensor:stats").incrByFloat("temp_sum", 22.3)
 *     sortedSet("sensor:anomalies").add(score = 45.0, member = "45")
 * }
 * ```
 *
 * Optimistic locking is supported via [watch] — the transaction aborts
 * (returning null from [Valkey.transaction]) if any watched key was
 * modified between WATCH and EXEC. Retry the block manually if you
 * need retry-until-success semantics.
 *
 * ```kotlin
 * val result = valkey.transaction {
 *     watch("sensor:stats")
 *     val currentCount = hash("sensor:stats").get("count")?.toLongOrNull() ?: 0L
 *     if (currentCount < 1000) hash("sensor:stats").incrBy("count", 1)
 * }
 * if (result == null) {
 *     // somebody else modified sensor:stats mid-flight, retry or give up
 * }
 * ```
 *
 * Inside the block, reads return the current values (the WATCH sees
 * them unmodified) while writes are **queued** — their return values
 * are the per-command replies collected in order when `EXEC` runs.
 * The Kotlin return type of write methods inside the block is the
 * same as outside (they return immediately with placeholder values)
 * but the observable effect only happens at EXEC.
 */
class TransactionScope internal constructor(private val dazzle: Dazzle) {
    internal val watchedKeys = mutableListOf<String>()

    /** WATCH key [key ...] — optimistic locking. Abort EXEC if any of
     *  these keys is modified between now and EXEC. */
    fun watch(vararg keys: String) {
        watchedKeys.addAll(keys)
    }

    // Inside the block, the consumer uses the normal primitive factories.
    // They go directly to directCommand() — Valkey queues commands received
    // between MULTI and EXEC server-side. The TransactionScope just exists
    // to host `watch()` and to differentiate "I'm inside a transaction" from
    // "I'm not" at the call site.
    fun string(key: String)       = dazzle.string(key)
    fun list(key: String)         = dazzle.list(key)
    fun hash(key: String)         = dazzle.hash(key)
    fun set(key: String)          = dazzle.set(key)
    fun sortedSet(key: String)    = dazzle.sortedSet(key)
    fun stream(key: String)       = dazzle.stream(key)
    fun bitmap(key: String)       = dazzle.bitmap(key)
    fun geo(key: String)          = dazzle.geo(key)
    fun hyperLogLog(key: String)  = dazzle.hyperLogLog(key)
}
