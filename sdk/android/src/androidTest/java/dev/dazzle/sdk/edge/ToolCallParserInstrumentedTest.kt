// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.JsonSchema
import dev.dazzle.sdk.ToolDeclaration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Pure-unit tests for the tool-call parser and its companion prompt
 * renderer. Runs on a connected device but does not touch the Valkey
 * engine — the parser is fully in-process Kotlin.
 */
@RunWith(AndroidJUnit4::class)
class ToolCallParserInstrumentedTest {

    // ── detectFromFilename ────────────────────────────────────────────

    @Test
    fun detectsGemmaFromFilename() {
        assertEquals(
            ToolCallSyntax.gemma,
            ToolCallPrompts.detectFromFilename("gemma-4-E2B-it.litertlm"),
        )
    }

    @Test
    fun detectsLlamaFromFilename() {
        assertEquals(
            ToolCallSyntax.llama32,
            ToolCallPrompts.detectFromFilename("llama-3.2-3b-instruct.litertlm"),
        )
    }

    @Test
    fun detectsQwenFromFilename() {
        assertEquals(
            ToolCallSyntax.qwen25,
            ToolCallPrompts.detectFromFilename("qwen-2.5-1.5b-instruct.litertlm"),
        )
    }

    @Test
    fun defaultsToGemmaForUnknownFilename() {
        assertEquals(
            ToolCallSyntax.gemma,
            ToolCallPrompts.detectFromFilename("phi3-mini.litertlm"),
        )
    }

    // ── Gemma dialect ─────────────────────────────────────────────────

    @Test
    fun parsesGemmaToolCallInOneChunk() {
        val parser = ToolCallParser(ToolCallSyntax.gemma)
        val stream = "I'll look that up.\n" +
            "<tool_call>{\"name\":\"weather.get\",\"arguments\":{\"city\":\"Lima\"}}</tool_call>"
        val deltas = parser.process(stream) + parser.flush()

        val texts = StringBuilder()
        val calls = mutableListOf<Triple<String, String, String>>()
        for (d in deltas) {
            when (d) {
                is Delta.Text          -> texts.append(d.chunk)
                is Delta.ToolCallStart -> calls.add(Triple(d.id, d.name, ""))
                is Delta.ToolCallArgs  -> {
                    val idx = calls.indexOfFirst { it.first == d.id }
                    if (idx >= 0) {
                        val old = calls[idx]
                        calls[idx] = Triple(old.first, old.second, old.third + d.argsChunk)
                    }
                }
                Delta.End              -> Unit
            }
        }
        assertEquals("I'll look that up.\n", texts.toString())
        assertEquals(1, calls.size)
        assertEquals("weather.get", calls[0].second)
        assertEquals("{\"city\":\"Lima\"}", calls[0].third)
    }

    @Test
    fun parsesGemmaToolCallAcrossChunkBoundary() {
        val parser = ToolCallParser(ToolCallSyntax.gemma)
        // Split the start delimiter in half: "<tool_" | "call>..."
        val deltas = mutableListOf<Delta>()
        deltas += parser.process("leading text <tool_")
        deltas += parser.process("call>{\"name\":\"a\",\"arguments\":{}}</tool_call> trailing")
        deltas += parser.flush()

        val texts = StringBuilder()
        val names = mutableListOf<String>()
        val args  = mutableListOf<String>()
        for (d in deltas) {
            when (d) {
                is Delta.Text          -> texts.append(d.chunk)
                is Delta.ToolCallStart -> names.add(d.name)
                is Delta.ToolCallArgs  -> args.add(d.argsChunk)
                Delta.End              -> Unit
            }
        }
        assertEquals("leading text  trailing", texts.toString())
        assertEquals(listOf("a"), names)
        assertEquals(listOf("{}"), args)
    }

    // ── Llama dialect ─────────────────────────────────────────────────

    @Test
    fun parsesLlamaToolCall() {
        val parser = ToolCallParser(ToolCallSyntax.llama32)
        val stream = "<|python_tag|>{\"name\":\"search\",\"parameters\":{\"q\":\"hi\"}}<|eom_id|>"
        val deltas = parser.process(stream) + parser.flush()

        val names = mutableListOf<String>()
        val args  = mutableListOf<String>()
        for (d in deltas) when (d) {
            is Delta.ToolCallStart -> names.add(d.name)
            is Delta.ToolCallArgs  -> args.add(d.argsChunk)
            else                   -> Unit
        }
        assertEquals(listOf("search"), names)
        assertEquals(listOf("{\"q\":\"hi\"}"), args)
    }

    // ── Qwen dialect (shares delimiters with Gemma) ──────────────────

    @Test
    fun parsesQwenToolCall() {
        val parser = ToolCallParser(ToolCallSyntax.qwen25)
        val stream = "<tool_call>{\"name\":\"q_fn\",\"arguments\":{\"n\":1}}</tool_call>"
        val deltas = parser.process(stream) + parser.flush()
        val names = deltas.filterIsInstance<Delta.ToolCallStart>().map { it.name }
        assertEquals(listOf("q_fn"), names)
    }

    // ── Edge cases ────────────────────────────────────────────────────

    @Test
    fun multipleToolCallsInOneStream() {
        val parser = ToolCallParser(ToolCallSyntax.gemma)
        val stream = """
            <tool_call>{"name":"a","arguments":{}}</tool_call>
            middle text
            <tool_call>{"name":"b","arguments":{"x":1}}</tool_call>
        """.trimIndent()
        val deltas = parser.process(stream) + parser.flush()
        val names = deltas.filterIsInstance<Delta.ToolCallStart>().map { it.name }
        assertEquals(listOf("a", "b"), names)
    }

    @Test
    fun malformedJsonFallsBackToTextDelta() {
        val parser = ToolCallParser(ToolCallSyntax.gemma)
        val stream = "<tool_call>not valid json</tool_call>"
        val deltas = parser.process(stream) + parser.flush()
        val joined = deltas.filterIsInstance<Delta.Text>().joinToString("") { it.chunk }
        assertTrue(joined.contains("<tool_call>"))
        assertTrue(joined.contains("</tool_call>"))
    }

    // ── Prompt rendering ──────────────────────────────────────────────

    @Test
    fun renderToolsSectionIncludesToolNameForGemma() {
        val declaration = ToolDeclaration(
            name = "weather.get",
            description = "Return the current weather for a city",
            parameters = JsonSchema.ObjectSchema(
                properties = mapOf(
                    "city" to JsonSchema.PrimitiveSchema(type = "string", description = "city name"),
                ),
                required = listOf("city"),
            ),
        )
        val section = ToolCallPrompts.renderToolsSection(listOf(declaration), ToolCallSyntax.gemma)
        assertTrue(section.contains("<tools>"))
        assertTrue(section.contains("weather.get"))
        assertTrue(section.contains("<tool_call>"))
    }

    @Test
    fun renderToolsSectionSwitchesToLlamaFormat() {
        val declaration = ToolDeclaration(
            name = "search",
            description = "Search the web",
            parameters = JsonSchema.ObjectSchema(
                properties = mapOf("q" to JsonSchema.PrimitiveSchema(type = "string")),
                required = listOf("q"),
            ),
        )
        val section = ToolCallPrompts.renderToolsSection(listOf(declaration), ToolCallSyntax.llama32)
        assertTrue(section.contains("<|python_tag|>"))
        assertTrue(section.contains("<|eom_id|>"))
        assertFalse(section.contains("<tool_call>"))
    }

    @Test
    fun renderToolsSectionEmptyReturnsEmpty() {
        assertEquals("", ToolCallPrompts.renderToolsSection(emptyList(), ToolCallSyntax.gemma))
    }
}
