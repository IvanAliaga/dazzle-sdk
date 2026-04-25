// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

package dev.dazzle.sdk.edge

import dev.dazzle.sdk.Delta

/**
 * Incremental parser that turns streaming text from a LiteRT-LM model
 * into `Delta` events, peeling out tool-call blocks from the assistant's
 * output and forwarding plain text verbatim.
 *
 * ### Wire formats
 *
 * - Gemma / Qwen2.5: `<tool_call>{"name":"...","arguments":{...}}</tool_call>`
 * - Llama 3.2:       `<|python_tag|>{"name":"...","parameters":{...}}<|eom_id|>`
 *
 * Both dialects wrap a single JSON object between two ASCII delimiters.
 * The parser uses a simple two-state machine (text / inside-call) and a
 * rolling buffer so it can handle any chunk boundary — including a
 * delimiter split across two chunks.
 *
 * ### Emission contract
 *
 * The parser never emits a partial `Delta.Text` that straddles a
 * potential delimiter. Whenever the tail of the buffer *could* be the
 * start of a delimiter we hold it back until the next `process` / `flush`
 * proves it otherwise. This mirrors how the OpenAI / Anthropic streaming
 * servers emit `content_block_delta` events: text out, tool call payload
 * separately.
 */
internal class ToolCallParser(syntax: ToolCallSyntax) {

    private val startDelim: String
    private val endDelim: String
    /** JSON field carrying the arguments dict — varies by dialect. */
    private val argsField: String

    init {
        val resolved = if (syntax == ToolCallSyntax.auto) ToolCallSyntax.gemma else syntax
        when (resolved) {
            ToolCallSyntax.gemma, ToolCallSyntax.qwen25 -> {
                startDelim = "<tool_call>"
                endDelim   = "</tool_call>"
                argsField  = "arguments"
            }
            ToolCallSyntax.llama32 -> {
                startDelim = "<|python_tag|>"
                endDelim   = "<|eom_id|>"
                argsField  = "parameters"
            }
            ToolCallSyntax.auto -> error("unreachable — resolved above")
        }
    }

    /** Rolling buffer of unemitted characters. */
    private val buf = StringBuilder()
    private var insideCall = false
    /** Monotonic counter so each tool_call gets a unique id inside a stream. */
    private var callSeq = 0

    /** Process the next chunk of raw model output. Returns zero or more
     *  deltas in emission order. */
    fun process(chunk: String): List<Delta> {
        val out = mutableListOf<Delta>()
        buf.append(chunk)
        drain(out, finalFlush = false)
        return out
    }

    /** Drain any remaining unemitted text. Call once when the underlying
     *  stream completes (before emitting `Delta.End`). */
    fun flush(): List<Delta> {
        val out = mutableListOf<Delta>()
        drain(out, finalFlush = true)
        return out
    }

    // ── Private ──────────────────────────────────────────────────────────

    private fun drain(out: MutableList<Delta>, finalFlush: Boolean) {
        while (true) {
            if (!insideCall) {
                val startIdx = buf.indexOf(startDelim)
                if (startIdx < 0) {
                    // No start marker. Emit everything EXCEPT the tail
                    // that might still match a start delimiter in a
                    // future chunk.
                    val safeLen = if (finalFlush) buf.length
                                  else maxOf(0, buf.length - (startDelim.length - 1))
                    if (safeLen > 0) {
                        out.add(Delta.Text(buf.substring(0, safeLen)))
                        buf.delete(0, safeLen)
                    }
                    return
                }
                // Emit the text that precedes the marker verbatim.
                if (startIdx > 0) {
                    out.add(Delta.Text(buf.substring(0, startIdx)))
                }
                buf.delete(0, startIdx + startDelim.length)
                insideCall = true
                // fall through to the inside-call branch
            } else {
                val endIdx = buf.indexOf(endDelim)
                if (endIdx < 0) {
                    if (!finalFlush) return
                    // Stream ended mid-call — surface whatever we got as
                    // text so the caller at least sees the raw bytes.
                    if (buf.isNotEmpty()) {
                        out.add(Delta.Text(startDelim + buf.toString()))
                        buf.clear()
                    }
                    insideCall = false
                    return
                }
                val payload = buf.substring(0, endIdx).trim()
                buf.delete(0, endIdx + endDelim.length)
                insideCall = false
                emitCall(payload, out)
                // loop in case another tool_call follows in the same buffer
            }
        }
    }

    /** Parse the JSON payload and emit a [Delta.ToolCallStart] +
     *  [Delta.ToolCallArgs] pair. On malformed input, fall back to
     *  emitting the raw payload as a Text delta so the caller still
     *  sees the model's output instead of swallowing it. */
    private fun emitCall(payload: String, out: MutableList<Delta>) {
        val name = extractJsonString(payload, "name")
        val args = extractJsonObject(payload, argsField)
        if (name == null || args == null) {
            out.add(Delta.Text(startDelim + payload + endDelim))
            return
        }
        val id = "tc_${++callSeq}"
        out.add(Delta.ToolCallStart(id = id, name = name))
        out.add(Delta.ToolCallArgs(id = id, argsChunk = args))
    }

    // ── Minimal JSON helpers ─────────────────────────────────────────────
    //
    // We deliberately avoid pulling kotlinx-serialization or org.json here:
    // this file lives in the library that consumers embed, so adding a
    // JSON dependency would bloat every app that ships an LLMClient of
    // their own. The tool-call payloads we target are tiny and well-formed
    // (the model emits them verbatim from its template), so a hand-rolled
    // extractor is enough.

    /** Extract the value of a top-level string field. Null if absent. */
    private fun extractJsonString(json: String, field: String): String? {
        val key = "\"$field\""
        val i = json.indexOf(key).takeIf { it >= 0 } ?: return null
        var p = i + key.length
        while (p < json.length && json[p].isWhitespace()) p++
        if (p >= json.length || json[p] != ':') return null
        p++
        while (p < json.length && json[p].isWhitespace()) p++
        if (p >= json.length || json[p] != '"') return null
        p++
        val sb = StringBuilder()
        while (p < json.length) {
            val c = json[p]
            if (c == '\\' && p + 1 < json.length) {
                val nxt = json[p + 1]
                sb.append(
                    when (nxt) {
                        '"'  -> '"'
                        '\\' -> '\\'
                        'n'  -> '\n'
                        'r'  -> '\r'
                        't'  -> '\t'
                        else -> nxt
                    }
                )
                p += 2
                continue
            }
            if (c == '"') return sb.toString()
            sb.append(c)
            p++
        }
        return null
    }

    /** Extract the textual JSON of a top-level object field (including
     *  the surrounding braces). Null if absent or malformed. */
    private fun extractJsonObject(json: String, field: String): String? {
        val key = "\"$field\""
        val i = json.indexOf(key).takeIf { it >= 0 } ?: return null
        var p = i + key.length
        while (p < json.length && json[p].isWhitespace()) p++
        if (p >= json.length || json[p] != ':') return null
        p++
        while (p < json.length && json[p].isWhitespace()) p++
        if (p >= json.length || json[p] != '{') return null
        // Match braces — support nested objects inside the args.
        var depth = 0
        val start = p
        while (p < json.length) {
            val c = json[p]
            when (c) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return json.substring(start, p + 1)
                }
                '"' -> {
                    // skip string content so braces inside strings don't
                    // confuse depth counting
                    p++
                    while (p < json.length) {
                        val s = json[p]
                        if (s == '\\' && p + 1 < json.length) { p += 2; continue }
                        if (s == '"') break
                        p++
                    }
                }
            }
            p++
        }
        return null
    }
}
