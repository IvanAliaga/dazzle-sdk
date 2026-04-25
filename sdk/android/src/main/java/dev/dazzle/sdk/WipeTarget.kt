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
 * Individual on-disk artifacts the library knows how to wipe from the
 * Valkey data directory.
 *
 * A [Set] of these is passed to [DazzleConfig.wipeOnStart] (to wipe
 * BEFORE the server boots) or to [DazzleServer.reset] (to wipe while
 * the server is running or stopped).
 *
 * The targets are granular on purpose — some users want to drop AOF
 * but keep RDB snapshots, others want to reset logs only without
 * touching data. Combine the enum values freely:
 *
 * ```kotlin
 * DazzleConfig(wipeOnStart = setOf(WipeTarget.AOF))                // AOF only
 * DazzleConfig(wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB)) // data
 * DazzleConfig(wipeOnStart = WipeTarget.ALL)                       // everything
 * ```
 */
enum class WipeTarget {
    /** Delete `appendonlydir/` — all AOF log files. */
    AOF,

    /** Delete `*.rdb` — RDB snapshot files. */
    RDB,

    /** Delete `valkey.log` — start each run with a clean log. */
    LOGS;

    companion object {
        /** Wipe nothing. Default for [DazzleConfig.wipeOnStart]. */
        val NONE: Set<WipeTarget> = emptySet()

        /** Wipe every known artifact in the data directory. */
        val ALL: Set<WipeTarget> = setOf(AOF, RDB, LOGS)
    }
}
