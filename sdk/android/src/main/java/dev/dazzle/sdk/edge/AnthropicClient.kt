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

import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.ToolDeclaration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * [LLMClient] that speaks Anthropic's `/v1/messages` wire format
 * (Claude). Distinct from `OpenAICompatibleClient` because Anthropic
 * uses a different shape:
 *
 *   * `system` is a top-level field (not a `messages[]` entry)
 *   * tool calls / tool results are represented as content **blocks**
 *     inside `content` arrays, not as a separate `tool_calls` field
 *   * tool schemas live under `input_schema`, not `parameters`
 *   * SSE frames carry `event: <name>\ndata: {...}` pairs with
 *     `content_block_*` and `message_*` events instead of OpenAI's
 *     unified `delta` chunks
 *   * `max_tokens` is **required**
 *
 * ## Example
 *
 * ```kotlin
 * val claude = AnthropicClient(
 *     model     = "claude-3-5-sonnet-latest",
 *     apiKey    = BuildConfig.ANTHROPIC_API_KEY,
 *     maxTokens = 1024,
 * )
 * val completion = claude.complete(
 *     listOf(Message(role = Role.user, content = "Hi")),
 * )
 * ```
 *
 * ## Tool-calling
 *
 * Both directions are auto-translated:
 *
 *   * outbound — `Message.toolCalls` (assistant) is rewritten as
 *     `content: [{type:"tool_use", id, name, input}]`; `tool` role
 *     turns become `{role:"user", content:[{type:"tool_result",
 *     tool_use_id, content}]}` (Anthropic's contract).
 *   * inbound — `tool_use` content blocks emit `Delta.ToolCallStart`
 *     once their `content_block_start` arrives, and the streamed
 *     `input_json_delta` payloads emit `Delta.ToolCallArgs`. This is
 *     the same surface every other Dazzle adapter exposes — the
 *     `ChatAgent` doesn't notice it's talking to Claude.
 *
 * ## Transport
 *
 * `HttpURLConnection` (Android SDK, no extra deps), SSE read on
 * [Dispatchers.IO], parsed with `org.json` — same playbook as the
 * OpenAI adapter so anyone reading both files stays oriented.
 */
class AnthropicClient(
    private val model: String,
    private val apiKey: String,
    private val baseURL: String = "https://api.anthropic.com/v1",
    private val anthropicVersion: String = "2023-06-01",
    private val maxTokens: Int = 1024,
    private val temperature: Double? = null,
    private val topP: Double? = null,
    private val extraHeaders: Map<String, String> = emptyMap(),
    private val connectTimeoutMs: Int = 30_000,
    private val readTimeoutMs: Int = 120_000,
) : LLMClient {

    override val modelId: String = model

    // ── complete (non-streaming) ─────────────────────────────────────────

    override suspend fun complete(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Completion = withContext(Dispatchers.IO) {
        val body = encodeBody(messages, tools, stream = false)
        val raw = httpPost(body, sse = false)
        decodeNonStreaming(raw)
    }

    // ── stream (SSE) ─────────────────────────────────────────────────────

    override fun stream(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Flow<Delta> = flow {
        val body = encodeBody(messages, tools, stream = true)
        val conn = openConnection(body, sse = true)
        try {
            val status = conn.responseCode
            if (status !in 200..299) {
                val errBody = (conn.errorStream ?: conn.inputStream)?.use {
                    BufferedReader(InputStreamReader(it, Charsets.UTF_8)).readText()
                } ?: "<empty>"
                throw AnthropicException.HttpError(status, errBody)
            }
            // Anthropic content-block streaming: `index` distinguishes
            // concurrent blocks (rare today, but the protocol allows
            // it). Track the (id, name) of every `tool_use` block by
            // its index so subsequent `input_json_delta` chunks can be
            // re-tagged with the tool-call id the agent expects.
            val liveBlocks = mutableMapOf<Int, BlockMeta>()

            BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (!line.startsWith("data: ")) continue
                    val payload = line.removePrefix("data: ").trim()
                    if (payload.isEmpty()) continue
                    val obj = try { JSONObject(payload) } catch (_: Throwable) { continue }
                    when (obj.optString("type")) {
                        "content_block_start" -> {
                            val index = obj.optInt("index", 0)
                            val block = obj.optJSONObject("content_block") ?: continue
                            when (block.optString("type")) {
                                "text" -> {
                                    liveBlocks[index] = BlockMeta(kind = "text")
                                }
                                "tool_use" -> {
                                    val id = block.optString("id", "tu_$index")
                                    val name = block.optString("name", "")
                                    liveBlocks[index] = BlockMeta(
                                        kind = "tool_use", id = id, name = name)
                                    emit(Delta.ToolCallStart(id = id, name = name))
                                }
                            }
                        }
                        "content_block_delta" -> {
                            val index = obj.optInt("index", 0)
                            val delta = obj.optJSONObject("delta") ?: continue
                            when (delta.optString("type")) {
                                "text_delta" -> {
                                    val text = delta.optString("text", "")
                                    if (text.isNotEmpty()) emit(Delta.Text(text))
                                }
                                "input_json_delta" -> {
                                    val meta = liveBlocks[index] ?: continue
                                    if (meta.kind != "tool_use") continue
                                    val frag = delta.optString("partial_json", "")
                                    if (frag.isNotEmpty()) {
                                        emit(Delta.ToolCallArgs(
                                            id = meta.id, argsChunk = frag))
                                    }
                                }
                            }
                        }
                        "message_stop" -> { /* clean end below */ }
                        // message_start, ping, content_block_stop,
                        // message_delta — informational, ignored.
                    }
                }
            }
            emit(Delta.End)
        } finally {
            conn.disconnect()
        }
    }.flowOn(Dispatchers.IO)

    override fun close() { /* per-call connections; nothing persistent. */ }

    // ── HTTP helpers ─────────────────────────────────────────────────────

    private fun httpPost(body: ByteArray, sse: Boolean): String {
        val conn = openConnection(body, sse)
        try {
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream
                         else (conn.errorStream ?: conn.inputStream)
            val text = BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).readText()
            if (status !in 200..299) {
                throw AnthropicException.HttpError(status, text)
            }
            return text
        } finally {
            conn.disconnect()
        }
    }

    private fun openConnection(body: ByteArray, sse: Boolean): HttpURLConnection {
        val url = URL(baseURL.trimEnd('/') + "/messages")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = connectTimeoutMs
        conn.readTimeout = readTimeoutMs
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setRequestProperty(
            "Accept",
            if (sse) "text/event-stream" else "application/json",
        )
        conn.setRequestProperty("x-api-key", apiKey)
        conn.setRequestProperty("anthropic-version", anthropicVersion)
        for ((k, v) in extraHeaders) conn.setRequestProperty(k, v)
        conn.outputStream.use { it.write(body) }
        return conn
    }

    // ── Wire encode (Dazzle Message[] → Anthropic body) ──────────────────

    private fun encodeBody(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
        stream: Boolean,
    ): ByteArray {
        val body = JSONObject()
        body.put("model", model)
        body.put("max_tokens", maxTokens)
        body.put("stream", stream)
        temperature?.let { body.put("temperature", it) }
        topP?.let { body.put("top_p", it) }

        // Anthropic separates `system` from `messages[]`. Concatenate
        // any role=system turns into one string (the chat agent only
        // injects one today, but be liberal in what you accept).
        val systemText = messages
            .filter { it.role == Role.system }
            .joinToString("\n\n") { it.content }
            .trim()
        if (systemText.isNotEmpty()) body.put("system", systemText)

        body.put("messages", JSONArray(buildMessages(messages)))

        if (tools.isNotEmpty()) {
            body.put("tools", JSONArray(tools.map(::wireTool)))
        }
        return body.toString().toByteArray(Charsets.UTF_8)
    }

    /**
     * Re-shape Dazzle `Message`s into Anthropic's `messages[]`. The
     * tricky pieces:
     *
     *   * assistant turns that include `toolCalls` become `content`
     *     arrays mixing `text` + `tool_use` blocks;
     *   * `tool` role turns become `user` turns with one
     *     `tool_result` block (Anthropic doesn't have a dedicated
     *     `tool` role — tool replies are user-side context);
     *   * empty assistant `content` is dropped (Anthropic 400s on
     *     blank text blocks).
     */
    private fun buildMessages(messages: List<Message>): List<JSONObject> {
        val out = mutableListOf<JSONObject>()
        for (m in messages) {
            when (m.role) {
                Role.system -> {} // handled separately
                Role.user -> {
                    val o = JSONObject()
                    o.put("role", "user")
                    o.put("content", m.content)
                    out += o
                }
                Role.assistant -> {
                    val blocks = JSONArray()
                    if (m.content.isNotEmpty()) {
                        val tb = JSONObject()
                        tb.put("type", "text")
                        tb.put("text", m.content)
                        blocks.put(tb)
                    }
                    for (tc in m.toolCalls) {
                        val tu = JSONObject()
                        tu.put("type", "tool_use")
                        tu.put("id", tc.id)
                        tu.put("name", tc.name)
                        // Dazzle stores arguments as a JSON string;
                        // Anthropic wants the parsed object under
                        // `input`. Falling back to {} keeps the wire
                        // valid even if the model emitted nothing
                        // before the args were complete.
                        val parsed = try { JSONObject(tc.arguments) }
                                     catch (_: Throwable) { JSONObject() }
                        tu.put("input", parsed)
                        blocks.put(tu)
                    }
                    if (blocks.length() == 0) continue // nothing to send
                    val o = JSONObject()
                    o.put("role", "assistant")
                    o.put("content", blocks)
                    out += o
                }
                Role.tool -> {
                    val tr = JSONObject()
                    tr.put("type", "tool_result")
                    tr.put("tool_use_id", m.toolCallId ?: "")
                    tr.put("content", m.content)
                    val arr = JSONArray()
                    arr.put(tr)
                    val o = JSONObject()
                    o.put("role", "user")
                    o.put("content", arr)
                    out += o
                }
            }
        }
        return out
    }

    private fun wireTool(d: ToolDeclaration): JSONObject {
        val schemaObj = JSONObject(d.parameters.serialize())
        val tool = JSONObject()
        tool.put("name", d.name)
        tool.put("description", d.description)
        tool.put("input_schema", schemaObj)
        return tool
    }

    // ── Non-streaming decode (Anthropic /messages → Completion) ──────────

    private fun decodeNonStreaming(raw: String): Completion {
        val obj = JSONObject(raw)
        val content = obj.optJSONArray("content")
            ?: throw AnthropicException.EmptyResponse
        var text = ""
        val calls = mutableListOf<ToolCall>()
        for (i in 0 until content.length()) {
            val block = content.optJSONObject(i) ?: continue
            when (block.optString("type")) {
                "text" -> text += block.optString("text", "")
                "tool_use" -> {
                    calls += ToolCall(
                        id        = block.optString("id", "tu_$i"),
                        name      = block.optString("name", ""),
                        arguments = block.optJSONObject("input")
                                        ?.toString() ?: "{}",
                    )
                }
            }
        }
        if (calls.isNotEmpty()) {
            return Completion.ToolCalls(
                Message(role = Role.assistant, content = text, toolCalls = calls)
            )
        }
        return Completion.Text(
            Message(role = Role.assistant, content = text)
        )
    }

    /** Streaming bookkeeping: which content block lives at this
     *  index, and (for tool_use blocks) the id+name we already
     *  surfaced so subsequent input_json_delta fragments inherit
     *  them. */
    private data class BlockMeta(
        val kind: String,
        val id: String = "",
        val name: String = "",
    )
}

/** Sealed error class for HTTP-level failures from the adapter. */
sealed class AnthropicException(msg: String) : RuntimeException(msg) {
    class HttpError(val status: Int, val body: String)
        : AnthropicException("Anthropic HTTP $status: $body")
    data object EmptyResponse
        : AnthropicException("Anthropic response had no content blocks")
}
