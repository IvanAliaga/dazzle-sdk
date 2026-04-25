// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Exercises the generic ContextStore<T> with two realistic shapes:
 *   ChatMessage      — role + text + timestamp (no embedding index here)
 *   SensorReading    — sensor id + temp + anomaly flag + timestamp
 *
 * The vector-search overload has its own dedicated suite in
 * [VectorIndexInstrumentedTest] — these tests focus on put/get/delete,
 * time range, tag intersection and iterate.
 */
@RunWith(AndroidJUnit4::class)
class ContextStoreInstrumentedTest : DazzleTestBase() {

    data class ChatMessage(val role: String, val text: String, val timestamp: Long)

    data class SensorReading(
        val sensorId: String,
        val temp: Double,
        val humidity: Double,
        val timestamp: Long,
        val anomalous: Boolean,
    )

    private fun chatStore(name: String = "chat:test") =
        dazzle.contextStore<ChatMessage>(name) {
            encode { m -> mapOf(
                "role" to m.role,
                "text" to m.text,
                "timestamp" to m.timestamp.toString(),
            ) }
            decode { f -> ChatMessage(
                role = f["role"].orEmpty(),
                text = f["text"].orEmpty(),
                timestamp = f["timestamp"]?.toLongOrNull() ?: 0L,
            ) }
            timeRange { it.timestamp }
            tags { setOf("role:${it.role}") }
        }

    private fun sensorStore(name: String = "sensors:test") =
        dazzle.contextStore<SensorReading>(name) {
            encode { r -> mapOf(
                "sensor_id" to r.sensorId,
                "temp" to r.temp.toString(),
                "humidity" to r.humidity.toString(),
                "timestamp" to r.timestamp.toString(),
                "anomalous" to r.anomalous.toString(),
            ) }
            decode { f -> SensorReading(
                sensorId = f["sensor_id"].orEmpty(),
                temp = f["temp"]?.toDoubleOrNull() ?: 0.0,
                humidity = f["humidity"]?.toDoubleOrNull() ?: 0.0,
                timestamp = f["timestamp"]?.toLongOrNull() ?: 0L,
                anomalous = f["anomalous"] == "true",
            ) }
            timeRange { it.timestamp }
            tags { r -> buildSet {
                add("sensor:${r.sensorId}")
                if (r.anomalous) add("anomalous")
            } }
        }

    @Test
    fun putThenGetRoundTripsTheRecord() {
        val chat = chatStore()
        try {
            chat.flush()
            chat.put("msg:1", ChatMessage("user", "hola", 1000L))
            val got = chat.get("msg:1")
            assertNotNull(got)
            assertEquals("user", got!!.role)
            assertEquals("hola", got.text)
            assertEquals(1000L, got.timestamp)
        } finally { chat.flush(); chat.close() }
    }

    @Test
    fun getOnMissingIdReturnsNull() {
        val chat = chatStore()
        try {
            assertNull(chat.get("never"))
        } finally { chat.close() }
    }

    @Test
    fun deleteRemovesRecordAndReportsExistence() {
        val chat = chatStore()
        try {
            chat.flush()
            chat.put("msg:2", ChatMessage("assistant", "bye", 2000L))
            assertTrue(chat.delete("msg:2"))
            assertNull(chat.get("msg:2"))
            assertFalse(chat.delete("msg:2"))   // second delete is a no-op
        } finally { chat.flush(); chat.close() }
    }

    @Test
    fun putAllAndCountMatch() {
        val chat = chatStore()
        try {
            chat.flush()
            chat.putAll(mapOf(
                "m:1" to ChatMessage("user", "a", 1000L),
                "m:2" to ChatMessage("assistant", "b", 2000L),
                "m:3" to ChatMessage("user", "c", 3000L),
            ))
            assertEquals(3L, chat.count())
        } finally { chat.flush(); chat.close() }
    }

    @Test
    fun byTimeRangeFiltersByTimestamp() {
        val chat = chatStore()
        try {
            chat.flush()
            chat.put("m:1", ChatMessage("user", "a", 100L))
            chat.put("m:2", ChatMessage("user", "b", 200L))
            chat.put("m:3", ChatMessage("user", "c", 300L))
            chat.put("m:4", ChatMessage("user", "d", 400L))

            val mid = chat.byTimeRange(start = 150L, end = 350L)
            assertEquals(setOf("m:2", "m:3"), mid.map { it.first }.toSet())
        } finally { chat.flush(); chat.close() }
    }

    @Test
    fun byTagReturnsMembersAcrossRecords() {
        val chat = chatStore()
        try {
            chat.flush()
            chat.put("m:1", ChatMessage("user", "a", 100L))
            chat.put("m:2", ChatMessage("assistant", "b", 200L))
            chat.put("m:3", ChatMessage("user", "c", 300L))

            val users = chat.byTag("role:user").map { it.first }.toSet()
            assertEquals(setOf("m:1", "m:3"), users)
        } finally { chat.flush(); chat.close() }
    }

    @Test
    fun byTagsIntersectsAcrossTagSets() {
        val sensors = sensorStore()
        try {
            sensors.flush()
            sensors.put("r:1", SensorReading("alpha", 22.0, 48.0, 1000L, anomalous = false))
            sensors.put("r:2", SensorReading("alpha", 45.0, 40.0, 2000L, anomalous = true))
            sensors.put("r:3", SensorReading("beta",  26.0, 55.0, 3000L, anomalous = true))

            // Intersection: sensor:alpha ∩ anomalous → only r:2.
            val hits = sensors.byTags(setOf("sensor:alpha", "anomalous"))
                .map { it.first }.toSet()
            assertEquals(setOf("r:2"), hits)
        } finally { sensors.flush(); sensors.close() }
    }

    @Test
    fun iterateYieldsAllStoredRecords() {
        val sensors = sensorStore()
        try {
            sensors.flush()
            repeat(5) { i ->
                sensors.put("r:$i", SensorReading("s$i", i.toDouble(), 50.0, i * 100L, false))
            }
            val ids = sensors.iterate().map { it.first }.toSet()
            assertEquals(setOf("r:0", "r:1", "r:2", "r:3", "r:4"), ids)
        } finally { sensors.flush(); sensors.close() }
    }

    @Test
    fun flushClearsRecordsAndIndices() {
        val chat = chatStore()
        try {
            chat.put("m:1", ChatMessage("user", "hello", 100L))
            chat.put("m:2", ChatMessage("user", "world", 200L))
            chat.flush()
            assertEquals(0L, chat.count())
            assertNull(chat.get("m:1"))
            assertTrue(chat.byTimeRange(0L, Long.MAX_VALUE).isEmpty())
        } finally { chat.close() }
    }

    @Test
    fun encodeReservedFieldIsRejected() {
        val bad = dazzle.contextStore<ChatMessage>("chat:bad") {
            encode { m -> mapOf("_embedding" to "stolen") }
            decode { ChatMessage("user", "x", 0L) }
        }
        try {
            try {
                bad.put("x", ChatMessage("user", "y", 0L))
                throw AssertionError("expected IllegalArgumentException for reserved field name")
            } catch (_: IllegalArgumentException) {
                // expected
            }
        } finally { bad.close() }
    }
}
