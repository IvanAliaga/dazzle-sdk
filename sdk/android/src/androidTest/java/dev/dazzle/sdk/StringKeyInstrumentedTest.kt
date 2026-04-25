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
class StringKeyInstrumentedTest : DazzleTestBase() {

    @Test
    fun setAndGetRoundTrip() {
        val k = dazzle.string("session:token")
        assertTrue(k.set("abc123"))
        assertEquals("abc123", k.get())
    }

    @Test
    fun getOnMissingKeyReturnsNull() {
        assertNull(dazzle.string("nope").get())
    }

    @Test
    fun nxGuardBlocksOverwrite() {
        val k = dazzle.string("once")
        assertTrue(k.set("first", StringKey.SetOptions(onlyIfAbsent = true)))
        // Second NX must be rejected.
        assertFalse(k.set("second", StringKey.SetOptions(onlyIfAbsent = true)))
        assertEquals("first", k.get())
    }

    @Test
    fun xxGuardBlocksCreate() {
        val k = dazzle.string("never")
        // XX on absent key must fail — key stays missing.
        assertFalse(k.set("x", StringKey.SetOptions(onlyIfPresent = true)))
        assertNull(k.get())
    }

    @Test
    fun incrAndIncrByAreAtomicIntegers() {
        val k = dazzle.string("counter")
        assertEquals(1L, k.incr())
        assertEquals(2L, k.incr())
        assertEquals(12L, k.incrBy(10))
        assertEquals(9L, k.decrBy(3))
        assertEquals(8L, k.decr())
    }

    @Test
    fun incrByFloatAddsDouble() {
        val k = dazzle.string("fcounter")
        k.set("10")
        val v = k.incrByFloat(2.5)
        assertEquals(12.5, v, 1e-9)
    }

    @Test
    fun appendAndLength() {
        val k = dazzle.string("blob")
        k.set("hello")
        assertEquals(11L, k.append(" world"))
        assertEquals(11L, k.length())
        assertEquals("hello world", k.get())
    }

    @Test
    fun deleteKeyRemovesValue() {
        val k = dazzle.string("ephemeral")
        k.set("gone")
        assertTrue(k.exists())
        assertTrue(k.deleteKey())
        assertFalse(k.exists())
    }

    @Test
    fun ttlSecondsSetsExpiry() {
        val k = dazzle.string("temp")
        assertTrue(k.set("v", StringKey.SetOptions(ttlSeconds = 60)))
        val ttl = dazzle.ttl("temp")
        assertTrue("ttl=$ttl should be > 0", ttl in 1..60)
    }
}
