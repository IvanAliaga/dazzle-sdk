// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HashKeyInstrumentedTest : DazzleTestBase() {

    @Test
    fun setGetAndSetAllRoundTrip() {
        val h = dazzle.hash("sensor:stats")
        assertTrue(h.set("count", "0"))
        assertEquals("0", h.get("count"))

        val written = h.setAll(mapOf("temp" to "22.3", "humidity" to "48"))
        // setAll reports the number of NEW fields; "count" stays unchanged
        // so only temp+humidity count here.
        assertEquals(2L, written)
        assertEquals("22.3", h.get("temp"))
    }

    @Test
    fun getOnMissingFieldReturnsNull() {
        val h = dazzle.hash("h1")
        h.set("present", "v")
        assertNull(h.get("absent"))
    }

    @Test
    fun mGetReturnsListAlignedWithInput() {
        val h = dazzle.hash("stats")
        h.setAll(mapOf("a" to "1", "b" to "2"))
        val values = h.mGet("a", "missing", "b")
        assertEquals(listOf("1", null, "2"), values)
    }

    @Test
    fun mGetDirectMatchesMGet() {
        val h = dazzle.hash("direct")
        h.setAll(mapOf("x" to "10", "y" to "20"))
        val fromPipe   = h.mGet("x", "y", "z")
        val fromDirect = h.mGetDirect("x", "y", "z")
        assertEquals(fromPipe, fromDirect)
    }

    @Test
    fun incrByAndIncrByFloatMutate() {
        val h = dazzle.hash("counters")
        assertEquals(1L, h.incrBy("hits", 1))
        assertEquals(11L, h.incrBy("hits", 10))
        val f = h.incrByFloat("score", 2.5)
        assertEquals(2.5, f, 1e-9)
    }

    @Test
    fun lengthAndKeysAndValues() {
        val h = dazzle.hash("h2")
        h.setAll(mapOf("a" to "1", "b" to "2", "c" to "3"))
        assertEquals(3L, h.length())
        assertEquals(setOf("a", "b", "c"), h.keys().toSet())
        assertEquals(setOf("1", "2", "3"), h.values().toSet())
    }

    @Test
    fun deleteFieldsReducesLength() {
        val h = dazzle.hash("h3")
        h.setAll(mapOf("a" to "1", "b" to "2", "c" to "3"))
        val removed = h.delete("a", "b", "missing")
        assertEquals(2L, removed)
        assertEquals(1L, h.length())
    }

    @Test
    fun deleteEntireKey() {
        val h = dazzle.hash("h4")
        h.set("k", "v")
        assertTrue(h.exists())
        assertTrue(h.delete())
        assertFalse(h.exists())
    }

    @Test
    fun getAllReflectsCurrentState() {
        val h = dazzle.hash("h5")
        h.setAll(mapOf("k1" to "v1", "k2" to "v2"))
        val all = h.getAll()
        assertEquals(mapOf("k1" to "v1", "k2" to "v2"), all)
    }
}
