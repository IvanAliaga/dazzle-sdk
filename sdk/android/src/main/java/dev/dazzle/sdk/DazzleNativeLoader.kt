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

import java.io.File

/**
 * Multi-target native loader.
 *
 * The Dazzle native binary ships in two flavours per arm64-v8a APK:
 *   - `libdazzle.so`     — `-march=armv8-a -mcpu=generic`
 *                           (cross-platform safe; the only build that runs
 *                            on Cortex-A53/A55/A73 baseline chips such as
 *                            Snapdragon 662, Kirin 659, MediaTek Helio G80
 *                            small cores, Kirin 710F).
 *   - `libdazzle_v82.so` — `-march=armv8.2-a+fp16+dotprod -mcpu=cortex-a78`
 *                           (HNSW search ~30 % faster on Unisoc T760,
 *                            MediaTek Helio G80 big cores, Snapdragon
 *                            695/8xx, any Cortex-A75+ chip that
 *                            advertises asimdhp + asimddp via
 *                            /proc/cpuinfo or AT_HWCAP).
 *
 * This loader picks one in `init {}` of every public entry point that
 * needs the native lib (`DazzleServer`, `VectorIndex`, `LlamaNative`),
 * so the first call from any thread settles the choice for the
 * lifetime of the process. The choice is logged to `dev.dazzle.sdk`
 * tag so a `logcat` line confirms which variant ran the bench.
 *
 * Detection prefers `/proc/cpuinfo` over `AT_HWCAP`: AT_HWCAP requires
 * a JNI call which would defeat the purpose (the JNI lib has not been
 * loaded yet), and `/proc/cpuinfo` exposes the same flags
 * (`asimdhp`, `asimddp`) on every Android kernel from 4.4 onward.
 *
 * The detection is safe to fail-closed: any I/O error, parse error, or
 * unexpected absence of the Features line falls back to the baseline
 * library, so a misread never causes a SIGILL.
 *
 * Fallback chain on UnsatisfiedLinkError:
 *   1. preferred (v82 or baseline depending on detection)
 *   2. the OTHER variant (so a stripped APK that only shipped one
 *      variant still loads)
 *   3. propagate the original error
 */
internal object DazzleNativeLoader {
    private const val TAG_LIB_BASELINE = "dazzle"
    private const val TAG_LIB_V82      = "dazzle_v82"

    @Volatile private var loaded: Boolean = false
    @Volatile private var loadedVariant: String = "<unloaded>"

    /** The variant that was actually loaded, for logging / paper tables. */
    @JvmStatic
    fun loadedVariantName(): String = loadedVariant

    /**
     * Override hook for the cross-platform "apples-to-apples" benchmark
     * pass: forcing every chip to run the same baseline binary makes
     * the §6.3 cross-platform table directly comparable across SoCs at
     * the cost of leaving the v8.2 perf headroom on the table on chips
     * that have it. Set via:
     *   - JVM system property `dazzle.force_native_variant`
     *   - ENV var `DAZZLE_FORCE_NATIVE_VARIANT`
     * Accepted values: `baseline`, `v82`, `auto` (default = auto-detect).
     *
     * Setting `v82` on a chip that does not advertise asimdhp + asimddp
     * is **unsafe** — the first SDOT or FP16 instruction will SIGILL.
     * The override exists for paper-table apples-to-apples runs, not
     * production tuning.
     */
    private const val PROP_KEY = "dazzle.force_native_variant"
    private const val ENV_KEY  = "DAZZLE_FORCE_NATIVE_VARIANT"

    private fun forcedVariant(): String? {
        val s = System.getProperty(PROP_KEY)?.takeIf { it.isNotBlank() }
            ?: System.getenv(ENV_KEY)?.takeIf { it.isNotBlank() }
            ?: return null
        return when (s.trim().lowercase()) {
            "baseline" -> TAG_LIB_BASELINE
            "v82"      -> TAG_LIB_V82
            "auto", "" -> null
            else -> {
                android.util.Log.w("dev.dazzle.sdk",
                    "$PROP_KEY='$s' is not a recognised variant; ignoring")
                null
            }
        }
    }

    /**
     * Idempotent. Safe to call from every entry-point's init. The first
     * call resolves which variant to load; subsequent calls are a
     * no-op.
     */
    @JvmStatic
    @Synchronized
    fun ensureLoaded() {
        if (loaded) return
        val forced = forcedVariant()
        val preferV82 = forced?.let { it == TAG_LIB_V82 } ?: preferV82Variant()
        val first  = if (preferV82) TAG_LIB_V82      else TAG_LIB_BASELINE
        val second = if (preferV82) TAG_LIB_BASELINE else TAG_LIB_V82
        if (forced != null) {
            android.util.Log.i(
                "dev.dazzle.sdk",
                "native variant override active: $PROP_KEY=$forced (auto-detect bypassed)",
            )
        }
        try {
            System.loadLibrary(first)
            loadedVariant = first
        } catch (e: UnsatisfiedLinkError) {
            // The preferred variant is missing or its dependencies are not
            // satisfied (e.g. a partial APK strip). Fall back to the other
            // one before giving up.
            android.util.Log.w(
                "dev.dazzle.sdk",
                "preferred native variant '$first' unavailable; falling back to '$second'",
                e,
            )
            System.loadLibrary(second)
            loadedVariant = second
        }
        loaded = true
        android.util.Log.i(
            "dev.dazzle.sdk",
            "loaded native variant=$loadedVariant (preferV82=$preferV82)",
        )
    }

    /**
     * True when /proc/cpuinfo advertises BOTH `asimdhp` (ARMv8.2 fp16)
     * and `asimddp` (ARMv8.2 SDOT). These are the two extensions the
     * v82 build relies on; without them the v82 binary SIGILLs on the
     * first FT.CREATE.
     *
     * On the four chips the paper covers:
     *   Unisoc T760 (Cortex-A76 big + A55 little)    — both flags    → v82
     *   Snapdragon 662 (Cortex-A73 big + A53 little) — neither flag  → baseline
     *   MediaTek Helio G80 (A75 big + A55 little)    — both flags    → v82
     *   Kirin 659 (Cortex-A53)                       — neither flag  → baseline
     */
    private fun preferV82Variant(): Boolean {
        return try {
            val cpuinfo = File("/proc/cpuinfo").takeIf { it.canRead() } ?: return false
            // The Features line is per-CPU on AArch64; we want the union
            // (a chip that has any core with the feature can run the
            // dispatched kernel — but in practice all cores share the
            // ID register). Read the file fully and look for both flags
            // anywhere in any Features line.
            var hasAsimdhp = false
            var hasAsimddp = false
            cpuinfo.useLines { lines ->
                for (raw in lines) {
                    if (!raw.startsWith("Features")) continue
                    val features = raw.substringAfter(':', "").trim()
                    if (features.isEmpty()) continue
                    // Token-based scan to avoid substring false positives.
                    for (tok in features.split(' ', '\t')) {
                        when (tok) {
                            "asimdhp" -> hasAsimdhp = true
                            "asimddp" -> hasAsimddp = true
                        }
                    }
                    if (hasAsimdhp && hasAsimddp) return@useLines
                }
            }
            hasAsimdhp && hasAsimddp
        } catch (t: Throwable) {
            android.util.Log.w(
                "dev.dazzle.sdk",
                "cpuinfo parse failed; loading baseline native variant",
                t,
            )
            false
        }
    }
}
