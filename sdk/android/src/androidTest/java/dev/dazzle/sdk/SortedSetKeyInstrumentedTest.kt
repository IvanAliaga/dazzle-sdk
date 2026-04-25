// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SortedSetKeyInstrumentedTest : DazzleTestBase() {

    @Test
    fun addAndScoreMatch() {
        val z = dazzle.sortedSet("leaderboard")
        assertTrue(z.add(10.0, "alice"))
        assertEquals(10.0, z.score("alice")!!, 1e-9)
        assertNull(z.score("missing"))
    }

    @Test
    fun addAllReturnsNewMemberCount() {
        val z = dazzle.sortedSet("z1")
        val added = z.addAll(mapOf("a" to 1.0, "b" to 2.0, "c" to 3.0))
        assertEquals(3L, added)
    }

    @Test
    fun rangeReturnsMembersInScoreOrder() {
        val z = dazzle.sortedSet("z2")
        z.addAll(mapOf("b" to 20.0, "a" to 10.0, "c" to 30.0))
        assertEquals(listOf("a", "b", "c"), z.range(0, -1))
    }

    @Test
    fun rangeByScoreFiltersWindow() {
        val z = dazzle.sortedSet("anomalies")
        z.addAll(mapOf("5" to 5.0, "15" to 15.0, "25" to 25.0, "35" to 35.0))
        assertEquals(listOf("15", "25"), z.rangeByScore(10.0, 30.0))
    }

    @Test
    fun rankAndRevRankMatchOrder() {
        val z = dazzle.sortedSet("z3")
        z.addAll(mapOf("a" to 1.0, "b" to 2.0, "c" to 3.0))
        assertEquals(0L, z.rank("a"))
        assertEquals(2L, z.rank("c"))
        assertEquals(0L, z.revRank("c"))
        assertEquals(2L, z.revRank("a"))
    }

    @Test
    fun incrByAdjustsExistingScore() {
        val z = dazzle.sortedSet("z4")
        z.add(10.0, "x")
        val after = z.incrBy("x", 2.5)
        assertEquals(12.5, after, 1e-9)
    }

    @Test
    fun removeDropsSpecificMembers() {
        val z = dazzle.sortedSet("z5")
        z.addAll(mapOf("a" to 1.0, "b" to 2.0, "c" to 3.0))
        val removed = z.remove("a", "missing")
        assertEquals(1L, removed)
        assertEquals(2L, z.cardinality())
    }

    @Test
    fun countRespectsScoreWindow() {
        val z = dazzle.sortedSet("z6")
        z.addAll(mapOf("a" to 1.0, "b" to 2.0, "c" to 3.0, "d" to 4.0))
        assertEquals(2L, z.count(2.0, 3.0))
    }

    @Test
    fun rangeWithScoresAttachesScore() {
        val z = dazzle.sortedSet("z7")
        z.addAll(mapOf("a" to 1.0, "b" to 2.0))
        val pairs = z.rangeWithScores(0, -1)
        assertEquals(2, pairs.size)
        assertEquals("a", pairs[0].member)
        assertEquals(1.0, pairs[0].score, 1e-9)
        assertEquals("b", pairs[1].member)
    }
}
