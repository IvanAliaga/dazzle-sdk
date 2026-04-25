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
 * Phase 2 A/B — SMEMBERS / ZRANGEBYSCORE / GET on the snapshot typed
 * path vs the RESP path. Mirrors the Phase 7 HGETALL benchmark so the
 * whole regression analysis lives in a single logcat search:
 *
 * ```
 * adb logcat -s Phase2Bench Phase7Bench
 * ```
 *
 * Records hot in the snapshot cache exercise the same code path that
 * ContextStore.byTag / byTimeRange / string-lookup hits.
 */
@RunWith(AndroidJUnit4::class)
class Phase2FastPathBenchmarkTest : DazzleTestBase() {

    override val modules: Set<DazzleModule> = emptySet()

    private val iterations = 5_000
    private val warmup     = 200

    // ── SMEMBERS ────────────────────────────────────────────────────────

    @Test
    fun smembers_respVsTyped() {
        val set = dazzle.set("bench:phase2:set1")
        set.add("alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta")

        repeat(warmup) { set.members() }
        repeat(warmup) { set.membersDirect() }

        var cksA = 0
        val tA = System.nanoTime()
        repeat(iterations) { cksA += set.members().size }
        val elapsedA = System.nanoTime() - tA

        var cksB = 0
        val tB = System.nanoTime()
        repeat(iterations) { cksB += set.membersDirect().size }
        val elapsedB = System.nanoTime() - tB

        val perA = elapsedA.toDouble() / iterations / 1_000.0
        val perB = elapsedB.toDouble() / iterations / 1_000.0
        Log.i("Phase2Bench", "SMEMBERS  RESP: %.2f µs/call  typed: %.2f µs/call  speedup: %.2fx  (cks %d/%d)"
            .format(perA, perB, perA / perB, cksA, cksB))
        set.deleteKey()
    }

    // ── ZRANGEBYSCORE ───────────────────────────────────────────────────

    @Test
    fun zrangeByScore_respVsTyped() {
        val z = dazzle.sortedSet("bench:phase2:zset1")
        // 20 timestamps over a 10-minute window.
        val now = System.currentTimeMillis()
        for (i in 0 until 20) z.add(score = (now - i * 30_000).toDouble(), member = "tc_$i")
        val min = (now - 10 * 60_000).toDouble()
        val max = now.toDouble()

        repeat(warmup) { z.rangeByScore(min, max) }
        repeat(warmup) { z.rangeByScoreDirect(min, max) }

        var cksA = 0
        val tA = System.nanoTime()
        repeat(iterations) { cksA += z.rangeByScore(min, max).size }
        val elapsedA = System.nanoTime() - tA

        var cksB = 0
        val tB = System.nanoTime()
        repeat(iterations) { cksB += z.rangeByScoreDirect(min, max).size }
        val elapsedB = System.nanoTime() - tB

        val perA = elapsedA.toDouble() / iterations / 1_000.0
        val perB = elapsedB.toDouble() / iterations / 1_000.0
        Log.i("Phase2Bench", "ZRANGEBY  RESP: %.2f µs/call  typed: %.2f µs/call  speedup: %.2fx  (cks %d/%d)"
            .format(perA, perB, perA / perB, cksA, cksB))
        z.deleteKey()
    }

    // ── GET ─────────────────────────────────────────────────────────────

    @Test
    fun getString_respVsTyped() {
        val s = dazzle.string("bench:phase2:str1")
        s.set("a reasonably sized string value that is representative of what an agent metadata blob looks like.")

        repeat(warmup) { s.get() }
        repeat(warmup) { s.getDirect() }

        var cksA = 0
        val tA = System.nanoTime()
        repeat(iterations) { cksA += s.get()?.length ?: 0 }
        val elapsedA = System.nanoTime() - tA

        var cksB = 0
        val tB = System.nanoTime()
        repeat(iterations) { cksB += s.getDirect()?.length ?: 0 }
        val elapsedB = System.nanoTime() - tB

        val perA = elapsedA.toDouble() / iterations / 1_000.0
        val perB = elapsedB.toDouble() / iterations / 1_000.0
        Log.i("Phase2Bench", "GET       RESP: %.2f µs/call  typed: %.2f µs/call  speedup: %.2fx  (cks %d/%d)"
            .format(perA, perB, perA / perB, cksA, cksB))
        s.deleteKey()
    }
}
