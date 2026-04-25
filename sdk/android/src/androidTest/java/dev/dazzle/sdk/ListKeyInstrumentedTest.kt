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
class ListKeyInstrumentedTest : DazzleTestBase() {

    @Test
    fun rpushThenRangeRetainsOrder() {
        val l = dazzle.list("queue")
        assertEquals(3L, l.rpush("a", "b", "c"))
        assertEquals(listOf("a", "b", "c"), l.range(0, -1))
        assertEquals(3L, l.length())
    }

    @Test
    fun lpushReversesInsertionOrder() {
        val l = dazzle.list("stack")
        l.lpush("a", "b", "c")
        // LPUSH inserts each value at the head, so "c" ends up at index 0.
        assertEquals(listOf("c", "b", "a"), l.range(0, -1))
    }

    @Test
    fun lpopRpopRemoveFromEnds() {
        val l = dazzle.list("deque")
        l.rpush("a", "b", "c", "d")
        assertEquals("a", l.lpop())
        assertEquals("d", l.rpop())
        assertEquals(listOf("b", "c"), l.range(0, -1))
    }

    @Test
    fun popOnEmptyReturnsNull() {
        val l = dazzle.list("empty")
        assertNull(l.lpop())
        assertNull(l.rpop())
    }

    @Test
    fun trimKeepsSubrangeOnly() {
        val l = dazzle.list("rolling")
        l.rpush("1", "2", "3", "4", "5")
        assertTrue(l.trim(1, 3))
        assertEquals(listOf("2", "3", "4"), l.range(0, -1))
    }

    @Test
    fun indexAndSetMutateByPosition() {
        val l = dazzle.list("idx")
        l.rpush("a", "b", "c")
        assertEquals("b", l.index(1))
        assertTrue(l.set(1, "B"))
        assertEquals("B", l.index(1))
    }

    @Test
    fun removeDropsMatchingEntries() {
        val l = dazzle.list("dedupe")
        l.rpush("x", "y", "x", "z", "x")
        val dropped = l.remove(count = 2, value = "x")
        assertEquals(2L, dropped)
        // remove count=2 removes the first 2 "x" occurrences from head → keeps the last one.
        assertEquals(listOf("y", "z", "x"), l.range(0, -1))
    }

    @Test
    fun deleteKeyRemovesList() {
        val l = dazzle.list("gone")
        l.rpush("a")
        assertTrue(l.exists())
        assertTrue(l.deleteKey())
        assertFalse(l.exists())
        assertEquals(0L, l.length())
    }
}
