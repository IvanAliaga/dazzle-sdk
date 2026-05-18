// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

package dev.dazzle.experiment

import java.io.File

/**
 * One-shot, cached probe of the host CPU's optional ARMv8 extensions.
 *
 * The caller-facing surface is a few `hasXxx()` predicates. The first
 * call parses `/proc/cpuinfo` once; subsequent calls return the cached
 * result. No JNI involved — the data already lives in /proc, and the
 * detection cost is in the microsecond range.
 *
 * Why we care:
 *
 * - **`asimdhp` (FEAT_FP16, ARMv8.2-A)** — native half-precision
 *   matmul. Without it, llama.cpp's flash-attention path falls back
 *   to fp16↔fp32 conversion on every dot-product, which **doubles**
 *   the compute and the working buffer. Defaulting `flashAttention`
 *   to off when this is missing keeps the slower-and-bigger path off
 *   chips that can't use it (e.g. Kirin 659 / Cortex-A53). On chips
 *   that have it (Helio G80 A75, SD662 A73 with v8.0+, T760 A76)
 *   flash-attention is a free win.
 *
 * - **`asimddp` (FEAT_DotProd)** — int8 dot-product. The runtime
 *   variant dispatcher in `DazzleNativeLoader` already uses this to
 *   pick `libdazzle_v82.so`; the predicate here is exposed for
 *   parity / debugging.
 *
 * Reference: ARM Architecture Reference Manual §A1.7 "Architectural
 * Feature Names" + Linux `arch/arm64/include/uapi/asm/hwcap.h`
 * (`HWCAP_ASIMDHP`, `HWCAP_ASIMDDP`).
 */
object CpuFeatures {

    @Volatile private var cached: Set<String>? = null

    private fun features(): Set<String> {
        cached?.let { return it }
        val parsed = try {
            File("/proc/cpuinfo")
                .readLines()
                .firstOrNull { it.startsWith("Features") }
                ?.substringAfter(":")
                ?.trim()
                ?.split(Regex("\\s+"))
                ?.toSet()
                ?: emptySet()
        } catch (_: Throwable) {
            emptySet()
        }
        cached = parsed
        return parsed
    }

    /**
     * `true` iff `/proc/cpuinfo` advertises `asimdhp`. Implies the chip
     * supports ARMv8.2 native fp16 matmul instructions (`FMLA Hd, Hn,
     * Hm[i]` & friends). Cortex-A75 / A76 / A77 / A78 / X1+ all have
     * it; Cortex-A53 / A55 / A57 / A72 / A73 do not.
     */
    fun hasFp16(): Boolean = "asimdhp" in features()

    /**
     * `true` iff `/proc/cpuinfo` advertises `asimddp`. Implies
     * ARMv8.2 dot-product (`SDOT`/`UDOT`). Same chips as `hasFp16`
     * in practice, with rare exceptions.
     */
    fun hasDotProd(): Boolean = "asimddp" in features()

    /** For diagnostic logging — the raw feature flag set. */
    fun raw(): Set<String> = features()
}
