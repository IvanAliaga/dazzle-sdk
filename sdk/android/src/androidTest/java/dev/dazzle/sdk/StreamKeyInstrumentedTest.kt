// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StreamKeyInstrumentedTest : DazzleTestBase() {

    @Test
    fun addReturnsIdAndLengthIncrements() {
        val s = dazzle.stream("sensor:readings")
        val id1 = s.add(mapOf("temp" to "22.3", "humidity" to "48"))
        val id2 = s.add(mapOf("temp" to "23.0", "humidity" to "47"))
        assertNotNull(id1)
        assertNotNull(id2)
        assertEquals(2L, s.length())
    }

    @Test
    fun rangeReturnsOldestFirst() {
        val s = dazzle.stream("ts")
        s.add(mapOf("v" to "1"))
        s.add(mapOf("v" to "2"))
        s.add(mapOf("v" to "3"))
        val out = s.range()
        assertEquals(3, out.size)
        assertEquals("1", out[0].fields["v"])
        assertEquals("3", out[2].fields["v"])
    }

    @Test
    fun revRangeReturnsNewestFirst() {
        val s = dazzle.stream("ts2")
        s.add(mapOf("v" to "1"))
        s.add(mapOf("v" to "2"))
        s.add(mapOf("v" to "3"))
        val out = s.revRange(count = 2)
        assertEquals(2, out.size)
        assertEquals("3", out[0].fields["v"])
        assertEquals("2", out[1].fields["v"])
    }

    @Test
    fun maxLenExactTrimsStrictly() {
        val s = dazzle.stream("bounded")
        for (i in 1..10) {
            s.add(mapOf("v" to i.toString()), maxLen = 5, trimStrategy = StreamKey.TrimStrategy.EXACT)
        }
        // EXACT trim must keep the stream at exactly maxLen regardless of
        // the ingest pattern. APPROX relies on radix-tree node boundaries
        // and can leave the stream slightly over the bound for small
        // corpora — not a useful assertion for a correctness test.
        assertEquals(5L, s.length())
    }

    @Test
    fun fieldsPreserveInsertionOrder() {
        val s = dazzle.stream("ordered")
        s.add(linkedMapOf("a" to "1", "b" to "2", "c" to "3"))
        val entries = s.range()
        assertEquals(1, entries.size)
        assertEquals(listOf("a", "b", "c"), entries[0].fields.keys.toList())
    }

    @Test
    fun deleteKeyRemovesStream() {
        val s = dazzle.stream("throwaway")
        s.add(mapOf("v" to "1"))
        assertTrue(s.exists())
        assertTrue(s.deleteKey())
        assertFalse(s.exists())
    }
}
