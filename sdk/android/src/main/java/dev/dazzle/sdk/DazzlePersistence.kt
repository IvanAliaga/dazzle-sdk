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
 * Persistence mode for an embedded Valkey instance — a mutually exclusive
 * choice between three states.
 *
 * Use [None] for ephemeral caches, tests and experiments where every boot
 * starts from a clean slate. Use [Aof] (default) for durable caches that
 * survive app restarts with bounded data loss. Use [Rdb] for workloads
 * that favor smaller on-disk footprint and faster boot over minimal data
 * loss.
 *
 * Valkey itself supports running AOF and RDB simultaneously. Dazzle
 * deliberately does not expose that combination because it adds I/O without
 * a clear win for the embedded mobile use case; if you need it, pass both
 * `--appendonly yes` and `--save "..."` via [DazzleConfig.extraArgs].
 */
sealed class DazzlePersistence {

    /**
     * In-memory only. No AOF, no RDB. Losing the process = losing the data.
     *
     * Best for:
     * - Tests and experiments (deterministic boots)
     * - Short-lived caches built from a canonical source
     * - Benchmarks where you want to exclude I/O from the measurement
     */
    data object None : DazzlePersistence()

    /**
     * Append-only log (`--appendonly yes`). Every write is appended to
     * `appendonly.aof.*`; Valkey replays the log on boot to reconstruct
     * the in-memory state. The [fsync] policy controls the durability
     * window.
     *
     * Default choice for app-level caches that need to survive a crash.
     */
    data class Aof(
        /** `--appendfsync` policy. See [AppendFsync] for the trade-offs. */
        val fsync: AppendFsync = AppendFsync.EVERYSEC,
    ) : DazzlePersistence()

    /**
     * Point-in-time snapshots (`--save "policy"`). Valkey forks and writes
     * a binary dump.rdb periodically; on boot it loads the last snapshot.
     * Writes since the last snapshot are lost on crash.
     *
     * Best for workloads that value small on-disk footprint and fast boot
     * over minimal data loss.
     */
    data class Rdb(
        /** `--save` argument. Defaults to Valkey's built-in triple rule:
         *  save after 3600 s if 1 key changed, 300 s if 100 keys changed,
         *  or 60 s if 10000 keys changed. */
        val savePolicy: String = DEFAULT_SAVE_POLICY,
    ) : DazzlePersistence()

    companion object {
        const val DEFAULT_SAVE_POLICY: String = "3600 1 300 100 60 10000"
    }
}

/**
 * AOF fsync policy. Only relevant when [DazzlePersistence.Aof] is selected.
 *
 * This is the classic Valkey / Redis durability knob — it trades how much
 * data you lose on a crash against how much the disk is hit on every write.
 */
enum class AppendFsync {
    /** `appendfsync always` — fsync after every write. Zero data loss,
     *  significant write latency. Rarely the right choice on mobile flash. */
    ALWAYS,

    /** `appendfsync everysec` — fsync once per second. At most ~1 second of
     *  writes lost on crash. Default Valkey recommendation. */
    EVERYSEC,

    /** `appendfsync no` — let the kernel decide. Best throughput, worst
     *  durability (can lose tens of seconds of writes). */
    NO,
}
