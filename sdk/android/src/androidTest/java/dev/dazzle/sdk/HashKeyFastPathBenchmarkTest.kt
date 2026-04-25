// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 7 A/B: measure `HashKey.getAll()` (RESP path) vs
 * `HashKey.getAllDirect()` (snapshot typed path) on the same record
 * hot in the snapshot cache. This is the regression we suspect broke
 * the SDK's lead over ObjectBox / SQLite-vector-ai when ContextStore
 * was unified onto the generic commandTyped(HGETALL) path.
 *
 * Prints both timings and the speedup ratio to logcat — run:
 *
 * ```
 * adb logcat -s Phase7Bench
 * ```
 *
 * while executing the test to see the numbers.
 */
@RunWith(AndroidJUnit4::class)
class HashKeyFastPathBenchmarkTest : DazzleTestBase() {

    override val modules: Set<DazzleModule> = emptySet()

    /** Typical ChatTurn-size payload: id + role + text + 2 meta fields. */
    private val sampleFields = linkedMapOf(
        "id"        to "tc_000001",
        "role"      to "assistant",
        "text"      to "The answer depends on whether the context window needs rolling summary compaction or a max-turns cap. " +
                      "For most chat apps max-turns with a window of 20-40 is enough; RAG builds that surface prior findings " +
                      "benefit from rolling summaries.",
        "timestamp" to "1732734123456",
        "tool_id"   to "",
    )

    @Test
    fun hgetallRespVsSnapshotTyped() {
        val hash = dazzle.hash("bench:phase7:record1")

        // Write once — mirror_write populates the snapshot entry so
        // every subsequent read should hit path B.
        hash.setAll(sampleFields)

        // Warmup both paths so we measure the steady state, not the
        // first-call JIT + fresh-allocation cost.
        val warmup = 200
        repeat(warmup) { hash.getAll() }
        repeat(warmup) { hash.getAllDirect() }

        val iterations = 5_000

        // ── Path A: RESP (commandTyped + RespParser) ───────────────────
        var checksumA = 0
        val startA = System.nanoTime()
        repeat(iterations) {
            val m = hash.getAll()
            checksumA += m.size   // keep the optimiser honest
        }
        val elapsedA = System.nanoTime() - startA

        // ── Path B: snapshot typed (no RESP) ───────────────────────────
        var checksumB = 0
        val startB = System.nanoTime()
        repeat(iterations) {
            val m = hash.getAllDirect()
            checksumB += m.size
        }
        val elapsedB = System.nanoTime() - startB

        val perA = elapsedA.toDouble() / iterations / 1_000.0    // µs/call
        val perB = elapsedB.toDouble() / iterations / 1_000.0    // µs/call
        val speedup = perA / perB

        Log.i("Phase7Bench",
            "n=$iterations   " +
            "getAll (RESP path)     : %.2f µs/call".format(perA))
        Log.i("Phase7Bench",
            "n=$iterations   " +
            "getAllDirect (typed)   : %.2f µs/call".format(perB))
        Log.i("Phase7Bench",
            "speedup                : ${"%.2fx".format(speedup)}")
        Log.i("Phase7Bench",
            "checksums (RESP/typed) : $checksumA / $checksumB (should match)")
        hash.delete()
    }
}
