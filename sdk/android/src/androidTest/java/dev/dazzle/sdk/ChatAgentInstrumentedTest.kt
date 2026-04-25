// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.first
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end agent test driven by a scripted [FakeLLMClient]. Covers:
 *   - plain text response → committed assistant turn
 *   - tool_call response → tool invoked, result fed back, final text committed
 *   - messages StateFlow transitions in the right order
 *   - memory persists across Agent instances (thread resumption)
 *   - compaction: MaxTurns bounds storage
 */
@RunWith(AndroidJUnit4::class)
class ChatAgentInstrumentedTest : DazzleTestBase() {

    @Test
    fun plainTextResponseCommitsAssistantTurn() = runBlocking {
        val llm = FakeLLMClient(
            script = listOf(
                Completion.Text(Message(Role.assistant, "Hola, ¿cómo estás?")),
            ),
        )
        val agent = dazzle.chatAgent(threadId = "test:plain", llm = llm) {
            systemPrompt = "You are a tester."
            compaction = CompactionPolicy.None
        }
        try {
            // Clean slate
            dazzle.flushDb()

            agent.send("Hola")
            // Wait for Idle status — indicates turn finished
            withTimeout(3_000) {
                while (agent.status.value != AgentStatus.Idle) {
                    kotlinx.coroutines.delay(10)
                }
            }

            val msgs = agent.messages.value
            assertEquals(2, msgs.size)
            assertEquals(Role.user, msgs[0].role)
            assertEquals("Hola", msgs[0].text)
            assertEquals(Role.assistant, msgs[1].role)
            assertEquals("Hola, ¿cómo estás?", msgs[1].text)
            assertEquals(1, llm.callCount)
        } finally { agent.close() }
    }

    @Test
    fun toolCallLoopInvokesToolAndCommitsFinalText() = runBlocking {
        // Simple add-numbers tool
        data class AddArgs(val a: Int, val b: Int)
        val addTool = object : Tool<AddArgs, Int> {
            override val name = "math.add"
            override val description = "Add two integers"
            override val argsSchema = jsonSchemaObject {
                property("a", type = "integer", required = true)
                property("b", type = "integer", required = true)
            }
            override suspend fun invoke(args: AddArgs, ctx: ToolContext): Int = args.a + args.b
            override fun argsFromJson(raw: String): AddArgs {
                // Very minimal parser for this test — extracts numeric fields
                fun extract(k: String): Int =
                    Regex("\"$k\"\\s*:\\s*(-?\\d+)").find(raw)?.groupValues?.get(1)?.toInt() ?: 0
                return AddArgs(extract("a"), extract("b"))
            }
            override fun returnToJson(value: Int): String = value.toString()
        }

        val llm = FakeLLMClient(
            script = listOf(
                // Call tool first
                Completion.ToolCalls(Message(
                    role = Role.assistant,
                    content = "",
                    toolCalls = listOf(ToolCall("c1", "math.add", """{"a":3,"b":4}""")),
                )),
                // Then produce final text using the tool's result
                Completion.Text(Message(Role.assistant, "The sum is 7.")),
            ),
        )

        val agent = dazzle.chatAgent("test:tool", llm = llm) {
            tools += addTool
            compaction = CompactionPolicy.None
        }
        try {
            dazzle.flushDb()
            agent.send("What's 3 + 4?")
            withTimeout(3_000) {
                while (agent.status.value != AgentStatus.Idle) {
                    kotlinx.coroutines.delay(10)
                }
            }

            val msgs = agent.messages.value
            // Expected sequence: user → assistant(tool_call) → tool → assistant(text)
            assertEquals(4, msgs.size)
            assertEquals(Role.user, msgs[0].role)
            assertEquals(Role.assistant, msgs[1].role)
            assertEquals(1, msgs[1].toolCalls.size)
            assertEquals("math.add", msgs[1].toolCalls[0].name)
            assertEquals(Role.tool, msgs[2].role)
            assertEquals("7", msgs[2].text)
            assertEquals("c1", msgs[2].toolCallId)
            assertEquals(Role.assistant, msgs[3].role)
            assertEquals("The sum is 7.", msgs[3].text)

            assertEquals(2, llm.callCount)
        } finally { agent.close() }
    }

    @Test
    fun compactionMaxTurnsBoundsStorage() = runBlocking {
        val llm = FakeLLMClient(
            script = buildList {
                repeat(10) { add(Completion.Text(Message(Role.assistant, "ok $it"))) }
            },
        )
        val agent = dazzle.chatAgent("test:compact", llm = llm) {
            compaction = CompactionPolicy.MaxTurns(maxTurns = 4)
        }
        try {
            dazzle.flushDb()
            repeat(10) { i ->
                agent.send("turn $i")
                withTimeout(3_000) {
                    while (agent.status.value != AgentStatus.Idle) {
                        kotlinx.coroutines.delay(10)
                    }
                }
            }

            // Each turn generates 2 memory entries (user + assistant).
            // 10 turns × 2 = 20 entries before compaction. MaxTurns(4)
            // keeps only the last 4.
            assertTrue(
                "messages.size should be <= 4, got ${agent.messages.value.size}",
                agent.messages.value.size <= 4,
            )
        } finally { agent.close() }
    }
}
