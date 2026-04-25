// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LuaScriptInstrumentedTest : DazzleTestBase() {

    @Test
    fun evalReturnsInteger() {
        val s = dazzle.script("return 42")
        val r = s.eval()
        assertEquals(42L, (r as RespValue.Integer).value)
    }

    @Test
    fun evalReadsKeysAndArgs() {
        val s = dazzle.script("""
            redis.call('SET', KEYS[1], ARGV[1])
            return redis.call('GET', KEYS[1])
        """.trimIndent())
        val reply = s.eval(keys = listOf("k1"), args = listOf("hello"))
        assertEquals("hello", (reply as RespValue.Bulk).value)
        assertEquals("hello", dazzle.string("k1").get())
    }

    @Test
    fun evalShaCachesAfterFirstEval() {
        val s = dazzle.script("return redis.call('INCR', KEYS[1])")
        val first = s.eval(keys = listOf("ctr"))
        val second = s.evalSha(keys = listOf("ctr"))
        assertEquals(1L, (first as RespValue.Integer).value)
        assertEquals(2L, (second as RespValue.Integer).value)
    }

    @Test
    fun loadReturnsSha1AndIsUsable() {
        val s = dazzle.script("return 'ok'")
        val sha = s.load()
        assertNotNull(sha)
        assertEquals(40, sha.length)         // SHA-1 hex = 40 chars
        val reply = s.evalSha()
        assertEquals("ok", (reply as RespValue.Bulk).value)
    }

    @Test
    fun twoScriptsHaveDifferentSha() {
        val a = dazzle.script("return 1")
        val b = dazzle.script("return 2")
        assertNotEquals(a.load(), b.load())
    }

    @Test
    fun atomicIncrementPattern() {
        // Typical edge-agent pattern: increment only if below a cap.
        val capIncrement = dazzle.script("""
            local cur = redis.call('GET', KEYS[1])
            if cur == false then cur = '0' end
            if tonumber(cur) < tonumber(ARGV[1]) then
                return redis.call('INCR', KEYS[1])
            else
                return -1
            end
        """.trimIndent())

        val counter = dazzle.string("bounded:counter")
        for (i in 1..5) {
            val v = capIncrement.eval(keys = listOf("bounded:counter"), args = listOf("3"))
            assertTrue(v is RespValue.Integer)
        }
        // After 3 increments the script returns -1 and the counter stops.
        val final = counter.get()?.toLongOrNull() ?: -1L
        assertEquals(3L, final)
    }
}
