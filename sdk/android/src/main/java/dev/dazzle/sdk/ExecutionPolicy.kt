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

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * Threading & concurrency configuration for the SDK.
 *
 * Dazzle sits on top of Valkey's classic single-event-loop model and adds
 * four **extra** concurrency primitives that stock Valkey does not have:
 *
 *   1. Snapshot cache + rwlock  → lock-free `directRead` bypassing the pipe
 *   2. Direct pipe commands     → JNI-level `directCommand` (no TCP)
 *   3. Pipelined direct writes  → N writes in 1 FFI crossing
 *   4. Parallel read worker pool → Plan 02, controlled by this policy
 *
 * All four are active by default; this class lets the consumer *tune* how
 * much of them to use. If you don't set anything, [balanced] is applied.
 *
 * The [dispatcher] is the Kotlin-native `CoroutineDispatcher` on which the
 * SDK runs its `suspend` surface. Use whichever dispatcher your app already
 * uses (Dispatchers.IO for standard server-like workloads, Dispatchers.Default
 * for CPU-heavy flows, Dispatchers.Main for UI-thread debug scripts, or any
 * custom `Executor.asCoroutineDispatcher()`).
 *
 * ## Recipe
 *
 * ```kotlin
 * // Battery-sensitive — no parallel reads, no IO threads
 * DazzleConfig(execution = ExecutionPolicy.lean)
 *
 * // Default balanced for a single agent on a phone
 * DazzleConfig(execution = ExecutionPolicy.balanced)
 *
 * // Multi-agent benchmarks / heavy concurrent searches
 * DazzleConfig(execution = ExecutionPolicy.parallel)
 *
 * // UI thread Playgrounds (runs Dazzle on Main — cap latency yourself!)
 * DazzleConfig(execution = ExecutionPolicy.mainThread())
 *
 * // Custom — pick and mix
 * DazzleConfig(execution = ExecutionPolicy(
 *     dispatcher     = Dispatchers.Default,
 *     readWorkers    = 2,           // 2 dedicated read-pool threads
 *     ioThreads      = 1,           // 1 Valkey IO thread for socket traffic
 *     commandTimeout = 10.seconds,
 * ))
 * ```
 */
data class ExecutionPolicy(
    /**
     * CoroutineDispatcher on which every `suspend fun` exposed by the SDK
     * runs. Defaults to [Dispatchers.IO] so the SDK never steals the main
     * thread by accident. Override with [Dispatchers.Default] for CPU-bound
     * workloads (HNSW searches, big summarizations) or with a custom
     * executor if your app has its own scheduling model.
     */
    val dispatcher: CoroutineDispatcher = Dispatchers.IO,

    /**
     * Size of the Dazzle parallel-read worker pool (Plan 02). Reads that
     * go through this pool (the vector-search hot path, for instance) can
     * execute concurrently on up to this many threads while the event
     * loop thread is free to process writes.
     *
     *   - `0` → disabled (every read serializes on the event loop)
     *   - `-1` → auto-pick: `min(ncpu - 1, 4)`
     *   - `N > 0` → fixed size N
     *
     * Enables the native `DAZZLE_PARALLEL_READS` code path. Ignored on
     * platforms that don't ship the worker pool in this build.
     */
    val readWorkers: Int = 0,

    /**
     * Valkey native IO threads (`--io-threads N`). They off-load socket
     * read/write from the event loop. Only meaningful when [tcpEnabled]
     * is true in [DazzleConfig]; `directCommand` / `directPipeline`
     * bypass sockets entirely and don't benefit from this knob.
     *
     *   - `0` → disabled (Valkey's default for embedded use)
     *   - `N > 0` → spawn N IO threads
     */
    val ioThreads: Int = 0,

    /**
     * Upper bound for any single command issued through the SDK's
     * suspend surface. Commands that take longer return a timeout error
     * instead of blocking the caller forever. Set to [Duration.INFINITE]
     * to disable. Does not apply to synchronous `directCommand` /
     * `directPipeline` — those are bounded by the pipe semantics.
     */
    val commandTimeout: Duration = 5.seconds,
) {
    init {
        require(readWorkers >= -1) {
            "readWorkers must be >= -1 (-1 = auto, 0 = off, N = fixed); got $readWorkers"
        }
        require(ioThreads >= 0) {
            "ioThreads must be >= 0 (0 = off, N = enable N threads); got $ioThreads"
        }
        require(commandTimeout.isPositive()) {
            "commandTimeout must be positive; got $commandTimeout"
        }
    }

    /**
     * Resolved worker-pool size after applying the auto rule.
     * Internal — used by DazzleServer.start when wiring env vars.
     */
    internal fun effectiveReadWorkers(cpuCount: Int): Int = when (readWorkers) {
        -1 -> (cpuCount - 1).coerceIn(1, 4)
        else -> readWorkers
    }

    companion object {
        /**
         * Minimal-resource profile. All concurrency knobs off — the SDK
         * runs everything on the event loop and the caller's dispatcher.
         * Best for battery-sensitive backgrounds or single-agent apps
         * that don't need parallel searches.
         */
        val lean: ExecutionPolicy = ExecutionPolicy(readWorkers = 0, ioThreads = 0)

        /**
         * Default for a single LLM agent on a phone. Parallel reads
         * enabled with auto sizing; IO threads off (in-process pipe
         * covers 99% of traffic).
         */
        val balanced: ExecutionPolicy = ExecutionPolicy(readWorkers = -1, ioThreads = 0)

        /**
         * Multi-agent / benchmark profile. Both parallel reads and IO
         * threads enabled. Use when many concurrent semantic searches
         * or TCP-served clients need to fan out across cores.
         */
        val parallel: ExecutionPolicy = ExecutionPolicy(readWorkers = -1, ioThreads = 2)

        /**
         * Runs the SDK's suspend surface on the Android main thread.
         * **Dev-mode only** — convenient for Playgrounds / Compose
         * previews but will jank the UI if you do anything expensive.
         * Set your own dispatcher override if needed.
         */
        @JvmOverloads
        fun mainThread(dispatcher: CoroutineDispatcher = Dispatchers.Main): ExecutionPolicy =
            ExecutionPolicy(dispatcher = dispatcher, readWorkers = 0, ioThreads = 0)
    }
}
