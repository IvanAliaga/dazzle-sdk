// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNoException
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Requires DazzleModule.VectorSearch — tests are skipped automatically if
 * the .so is not present in the test APK's native lib directory.
 */
@RunWith(AndroidJUnit4::class)
class VectorIndexInstrumentedTest : DazzleTestBase() {

    override val modules: Set<DazzleModule> = setOf(DazzleModule.VectorSearch)

    // Use a tiny FLAT index so assertions are deterministic across runs.
    private lateinit var index: VectorIndex

    @Before
    fun createFlatIndex() {
        // Skip the whole suite if the vector-search .so is missing — that's
        // expected on builds that don't ship the module.
        try {
            index = dazzle.vectorIndex(
                name = "t_flat",
                hashPrefix = "vf:",
                dim = 4,
                algorithm = VectorIndex.Algorithm.FLAT,
                metric = VectorIndex.Metric.L2,
            )
            // flushDb() from DazzleTestBase clears keys but NOT the
            // valkey-search index metadata (that lives in the module's
            // private state, not the keyspace). Drop any stale index before
            // recreating so each test starts from a clean schema.
            index.drop()
            assertTrue("index.create() returned false", index.create())
        } catch (e: DazzleException.ModuleUnavailable) {
            assumeNoException(e)
        }
    }

    @Test
    fun addAndSearchFindsNearestNeighbor() {
        index.add("vf:1", floatArrayOf(1f, 0f, 0f, 0f))
        index.add("vf:2", floatArrayOf(0f, 1f, 0f, 0f))
        index.add("vf:3", floatArrayOf(0f, 0f, 1f, 0f))

        val q = floatArrayOf(0.9f, 0.1f, 0f, 0f)
        val hits = index.search(q, k = 2)
        assertEquals(2, hits.size)
        assertEquals("vf:1", hits[0].id)  // closest to q
    }

    @Test
    fun searchReturnsScoresAscending() {
        index.add("vf:a", floatArrayOf(0f, 0f, 0f, 0f))
        index.add("vf:b", floatArrayOf(10f, 0f, 0f, 0f))
        index.add("vf:c", floatArrayOf(20f, 0f, 0f, 0f))
        val hits = index.search(floatArrayOf(0f, 0f, 0f, 0f), k = 3)
        assertEquals(listOf("vf:a", "vf:b", "vf:c"), hits.map { it.id })
        for (i in 1 until hits.size) {
            assertTrue(
                "scores should be ascending: ${hits[i - 1].score} > ${hits[i].score}",
                hits[i - 1].score <= hits[i].score,
            )
        }
    }

    @Test
    fun searchWithMetadataStoresAndReturnsId() {
        // FT.HADD persists metadata in the underlying hash, but the current
        // RESP parser on FT.SEARCH only surfaces the distance-score field —
        // downstream metadata is retrieved via a follow-up HGETALL in the
        // experiment code rather than through SearchResult.fields. Mirror
        // the iOS VectorIndexTests constraint until that parser gap lands.
        index.add("vf:10", floatArrayOf(1f, 0f, 0f, 0f), metadata = mapOf("tag" to "A"))
        index.add("vf:11", floatArrayOf(0f, 1f, 0f, 0f), metadata = mapOf("tag" to "B"))
        val hits = index.search(floatArrayOf(1f, 0f, 0f, 0f), k = 1)
        assertEquals(1, hits.size)
        assertEquals("vf:10", hits[0].id)
    }

    @Test
    fun dropRemovesTheIndex() {
        assertTrue(index.drop())
        // After drop, search should return 0 hits — the index name is gone.
        val hits = index.search(floatArrayOf(0f, 0f, 0f, 0f), k = 1)
        assertTrue(hits.isEmpty())
    }

    @Test
    fun wrongDimensionThrows() {
        try {
            index.add("vf:bad", floatArrayOf(1f, 2f))  // dim mismatch
            throw AssertionError("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    // ── Fast-path: addDirect / searchDirect / addBatchDirect ────────────

    @Test
    fun addDirectAndSearchDirect() {
        val idx = dazzle.vectorIndex(
            name        = "t_hnsw_direct",
            hashPrefix  = "vd:",
            dim         = 4,
            algorithm   = VectorIndex.Algorithm.HNSW,
            metric      = VectorIndex.Metric.COSINE,
        )
        idx.drop()
        assertTrue("idx.create() returned false", idx.create())

        idx.addDirect("vd:1", floatArrayOf(1f, 0f, 0f, 0f))
        idx.addDirect("vd:2", floatArrayOf(0f, 1f, 0f, 0f))
        idx.addDirect("vd:3", floatArrayOf(0f, 0f, 1f, 0f))

        val hits = idx.searchDirect(floatArrayOf(0.9f, 0.1f, 0f, 0f), k = 2)
        assertEquals(2, hits.size)
        assertEquals("vd:1", hits.first().first)
        for (i in 1 until hits.size) {
            assertTrue(
                "distances should be ascending",
                hits[i - 1].second <= hits[i].second,
            )
        }
        idx.drop()
    }

    @Test
    fun addBatchDirectMatchesSerialAdd() {
        val idx = dazzle.vectorIndex(
            name        = "t_hnsw_batch",
            hashPrefix  = "vb:",
            dim         = 4,
            algorithm   = VectorIndex.Algorithm.HNSW,
            metric      = VectorIndex.Metric.COSINE,
        )
        idx.drop()
        assertTrue("idx.create() returned false", idx.create())

        val ids = arrayOf("vb:1", "vb:2", "vb:3", "vb:4")
        val vecs = arrayOf(
            floatArrayOf(1f, 0f, 0f, 0f),
            floatArrayOf(0f, 1f, 0f, 0f),
            floatArrayOf(0f, 0f, 1f, 0f),
            floatArrayOf(0f, 0f, 0f, 1f),
        )
        idx.addBatchDirect(ids, vecs)

        val hits = idx.searchDirect(floatArrayOf(0.8f, 0f, 0.1f, 0f), k = 4)
        assertEquals(4, hits.size)
        assertEquals(ids.toSet(), hits.map { it.first }.toSet())
        assertEquals("vb:1", hits.first().first)  // cosine winner
        idx.drop()
    }

    // ── SQ8 and F16 quantised paths ─────────────────────────────────────

    @Test
    fun hnswSq8RetrievesExactMatch() {
        val idx = dazzle.vectorIndex(
            name        = "t_sq8",
            hashPrefix  = "sq8:",
            dim         = 8,
            algorithm   = VectorIndex.Algorithm.HNSW_SQ8,
            metric      = VectorIndex.Metric.COSINE,
        )
        idx.drop()
        assertTrue("idx.create() returned false", idx.create())

        idx.addDirect("sq8:a", floatArrayOf(1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f))
        idx.addDirect("sq8:b", floatArrayOf(0f, 1f, 0f, 0f, 0f, 0f, 0f, 0f))
        idx.addDirect("sq8:c", floatArrayOf(0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f))

        val hits = idx.searchDirect(floatArrayOf(0.95f, 0.05f, 0f, 0f, 0f, 0f, 0f, 0f), k = 2)
        assertEquals(2, hits.size)
        assertEquals("sq8:a", hits.first().first)
        idx.drop()
    }

    @Test
    fun hnswSq8RerankOrdersLikeFp32() {
        val idx = dazzle.vectorIndex(
            name        = "t_sq8_rerank",
            hashPrefix  = "sr:",
            dim         = 8,
            algorithm   = VectorIndex.Algorithm.HNSW_SQ8_RERANK,
            metric      = VectorIndex.Metric.COSINE,
        )
        idx.drop()
        assertTrue("idx.create() returned false", idx.create())

        idx.addDirect("sr:a", floatArrayOf(1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f))
        idx.addDirect("sr:b", floatArrayOf(0.707f, 0.707f, 0f, 0f, 0f, 0f, 0f, 0f))
        idx.addDirect("sr:c", floatArrayOf(0f, 1f, 0f, 0f, 0f, 0f, 0f, 0f))

        val hits = idx.searchDirect(floatArrayOf(0.9f, 0.1f, 0f, 0f, 0f, 0f, 0f, 0f), k = 3)
        assertEquals(3, hits.size)
        assertEquals("sr:a", hits.first().first)
        for (i in 1 until hits.size) {
            assertTrue(
                "distances should be ascending after rerank",
                hits[i - 1].second <= hits[i].second,
            )
        }
        idx.drop()
    }

    @Test
    fun hnswF16RetrievesNearestNeighbor() {
        val idx = dazzle.vectorIndex(
            name        = "t_f16",
            hashPrefix  = "f16:",
            dim         = 8,
            algorithm   = VectorIndex.Algorithm.HNSW_F16,
            metric      = VectorIndex.Metric.COSINE,
        )
        idx.drop()
        assertTrue("idx.create() returned false", idx.create())

        idx.addDirect("f16:a", floatArrayOf(1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f))
        idx.addDirect("f16:b", floatArrayOf(0f, 1f, 0f, 0f, 0f, 0f, 0f, 0f))
        idx.addDirect("f16:c", floatArrayOf(0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f))

        val hits = idx.searchDirect(floatArrayOf(0.95f, 0.05f, 0f, 0f, 0f, 0f, 0f, 0f), k = 1)
        assertEquals(1, hits.size)
        assertEquals("f16:a", hits.first().first)
        idx.drop()
    }
}
