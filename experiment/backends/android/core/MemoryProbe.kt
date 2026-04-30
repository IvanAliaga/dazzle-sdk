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

package dev.dazzle.experiment

import java.io.File

/**
 * Process-memory probes for the storage / scale benches.
 *
 * VmRSS counts every page mapped into the process, including pages
 * shared with libc, the framework, JIT code caches, and any neighbour
 * process that happens to hold the same physical page (which on Android
 * is most of the runtime). For a "how much extra memory does my
 * backend take?" question that's misleading: a backend that allocates
 * 2 MB of new private heap can show a 30 MB RSS delta because of
 * unrelated runtime warm-up.
 *
 * Pss (Proportional Set Size) attributes shared pages proportionally
 * across the processes that map them, so it tracks new private growth
 * accurately. We prefer Pss when /proc/self/smaps_rollup is readable
 * (Android 8+) and fall back to VmRSS on older / locked-down devices.
 *
 * The GC quiesce wrapper exists for the same reason: the Dalvik /
 * ART heap can grow lazily, so a VmRSS reading right after ingest
 * picks up uncollected garbage from the warm-up phase too. Forcing
 * a GC before each measurement bounds that noise.
 *
 * Note on the noise floor: at small N (e.g. 200 readings, ~50 KB of
 * payload) the storage delta is well under the GC noise floor of any
 * Android process (~MB-scale). Use [scale_benchmark] at N≥20k for
 * defensible PSS deltas, and use the per-backend `backendSizeBytes()`
 * accounting for noise-free attribution at any N.
 */
object MemoryProbe {

    /**
     * Single atomic-ish snapshot of the relevant /proc counters.
     *
     * The fields are read back-to-back after one shared quiesce so
     * primaryKb (Pss when available, Rss as fallback) and the explicit
     * pssKb / rssKb fields agree by construction. Earlier versions of
     * this helper exposed three independent functions which were called
     * in sequence by the bench, with the unfortunate consequence that
     * `ram_delta_kb` ≠ `ram_delta_pss_kb` in the JSON because the kernel
     * reads were spaced apart by enough wall-clock time for other
     * threads or background GC to move pages.
     */
    data class Snapshot(
        val pssKb: Long,
        val rssKb: Long,
    ) {
        val primaryKb: Long get() = if (pssKb > 0) pssKb else rssKb
        val metric: String get() = if (pssKb > 0) "pss" else "rss"
    }

    /** Read PSS without quiescing — useful when the caller already did. */
    fun pssKb(): Long = try {
        File("/proc/self/smaps_rollup").readLines()
            .firstOrNull { it.startsWith("Pss:") }
            ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull() ?: -1
    } catch (_: Exception) { -1 }

    /** Read VmRSS without quiescing — always available. */
    fun rssKb(): Long = try {
        File("/proc/self/status").readLines()
            .firstOrNull { it.startsWith("VmRSS") }
            ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull() ?: -1
    } catch (_: Exception) { -1 }

    /**
     * Best-effort GC quiesce: 3 rounds of GC + finalizer drain with
     * a short pause between rounds. Costs ~600 ms total; cheap
     * relative to the workload we're measuring.
     */
    fun quiesce() {
        val rt = Runtime.getRuntime()
        repeat(3) {
            rt.gc()
            System.runFinalization()
            try { Thread.sleep(200) } catch (_: InterruptedException) { return }
        }
    }

    /**
     * Quiesce once, then read all metrics back-to-back. Returned snapshot
     * is internally consistent: `primaryKb` is `pssKb` when available and
     * `rssKb` otherwise, with no extra read in between.
     */
    fun snapshot(): Snapshot {
        quiesce()
        return Snapshot(pssKb = pssKb(), rssKb = rssKb())
    }
}
