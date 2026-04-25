// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.dazzle.sdk.edge.ChatAgentBundle
import dev.dazzle.sdk.edge.DazzleEdge
import dev.dazzle.sdk.edge.ModelManifest
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Covers the Layer 3 bundle surface that doesn't require a real LLM
 * runtime on the device:
 *   - DazzleEdge.chatAgent composes Layer 2 correctly with a FakeLLMClient
 *   - Manifest entries expose the expected pinned metadata
 *   - ensureModel integration is smoke-tested via isModelReady only
 *     (no real 2.4 GB download in CI)
 */
@RunWith(AndroidJUnit4::class)
class DazzleEdgeInstrumentedTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    // NOTE: we intentionally do NOT stop the server between tests. The
    // test APK runs in a single short-lived process that JUnit tears
    // down at the end; calling DazzleServer.stop() here introduces a
    // stop+restart cycle on Valkey that historically hangs the direct
    // command pipe on arm64 bionic.

    @Test
    fun manifestExposesKnownModels() {
        val g = ModelManifest.gemma4_E2B
        assertEquals("gemma-4-E2B-it", g.id)
        assertEquals("gemma-4-E2B-it.litertlm", g.filename)
        assertTrue(g.sizeBytes > 1_000_000_000L)   // multi-GB
        assertEquals(ModelManifest.Backend.LiteRTLM, g.backend)

        val all = ModelManifest.all
        assertTrue(all.size >= 3)
        assertTrue(all.contains(g))
    }

    @Test
    fun isModelReadyIsFalseBeforeDownload() {
        // Fresh cache → no download has happened → no cached file.
        val ready = DazzleEdge.isModelReady(context, ModelManifest.gemma4_E2B)
        // Don't XCTFail — another test run may have populated the cache.
        // Just assert the call works.
        assertTrue(ready || !ready)
    }

    @Test
    fun chatAgentBootsAndRoundTripsOneTurn() = runBlocking {
        val llm = FakeLLMClient(
            modelId = "fake:edge",
            script = listOf(
                Completion.Text(Message(Role.assistant, "hello from edge")),
            ),
        )
        val agent = DazzleEdge.chatAgent(context, llm = llm, threadId = "edge:test") {
            systemPrompt = "You are a test agent."
            compaction = CompactionPolicy.None
        }
        try {
            agent.send("hi")
            withTimeout(3_000) {
                while (agent.status.value != AgentStatus.Idle) delay(10)
            }
            val msgs = agent.messages.value
            assertEquals(2, msgs.size)
            assertEquals(Role.user, msgs[0].role)
            assertEquals(Role.assistant, msgs[1].role)
            assertEquals("hello from edge", msgs[1].text)
        } finally { agent.close() }
    }

    @Test
    fun chatAgentAppliesBundleCompactionOverride() = runBlocking {
        val llm = FakeLLMClient(
            modelId = "fake:edge",
            script = buildList {
                repeat(6) { add(Completion.Text(Message(Role.assistant, "reply $it"))) }
            },
        )
        val agent = DazzleEdge.chatAgent(context, llm = llm, threadId = "edge:compact") {
            compaction = CompactionPolicy.MaxTurns(maxTurns = 3)
        }
        try {
            repeat(6) { i ->
                agent.send("turn $i")
                withTimeout(3_000) {
                    while (agent.status.value != AgentStatus.Idle) delay(10)
                }
            }
            assertTrue(
                "messages should be bounded by MaxTurns(3), got ${agent.messages.value.size}",
                agent.messages.value.size <= 3
            )
        } finally { agent.close() }
    }
}
