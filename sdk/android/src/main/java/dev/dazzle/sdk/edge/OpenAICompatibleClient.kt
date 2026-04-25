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
 * [LLMClient] that speaks the OpenAI `chat/completions` wire format.
 *
 * Any host that serves `/v1/chat/completions` with the OpenAI schema
 * works: OpenAI itself, Azure OpenAI, Groq, Together AI, HuggingFace
 * Inference Providers (`router.huggingface.co/v1`), Ollama local
 * (`localhost:11434/v1`), vLLM, LM Studio, an OpenRouter proxy, or
 * any FastAPI you write yourself.
 *
 * ## Examples
 *
 * ```kotlin
 * // OpenAI
 * val openai = OpenAICompatibleClient(
 *     baseURL = "https://api.openai.com/v1",
 *     model   = "gpt-4o-mini",
 *     apiKey  = BuildConfig.OPENAI_API_KEY,
 * )
 *
 * // HuggingFace Inference (any HF-hosted model)
 * val hf = OpenAICompatibleClient(
 *     baseURL = "https://router.huggingface.co/v1",
 *     model   = "meta-llama/Llama-3.3-70B-Instruct",
 *     apiKey  = BuildConfig.HF_TOKEN,
 * )
 *
 * // Ollama running on the dev machine, reachable from the emulator
 * val ollama = OpenAICompatibleClient(
 *     baseURL = "http://10.0.2.2:11434/v1",
 *     model   = "llama3.2",
 * )
 * ```
 *
 * ## Tool-calling
 *
 * Native wire-format — when the remote reply includes `tool_calls`
 * they are surfaced directly as `Delta.ToolCallStart` +
 * `Delta.ToolCallArgs` (and as `Completion.ToolCalls` from
 * [complete]). No extra parser required.
 *
 * ## Transport
 *
 * Uses `HttpURLConnection` (Android SDK, no external deps). SSE
 * frames are read line-by-line from the response body on
 * [Dispatchers.IO] and parsed with `org.json`.
 *
 * ## Cleartext and ATS
 *
 * For `http://` base URLs (e.g. local Ollama over the emulator
 * bridge `10.0.2.2:11434`), the consumer app must opt in via
 * `android:usesCleartextTraffic="true"` or a
 * `network_security_config.xml` — the SDK does not relax that for
 * you.
 */
class OpenAICompatibleClient(
    private val baseURL: String,
    private val model: String,
    private val apiKey: String? = null,
    private val extraHeaders: Map<String, String> = emptyMap(),
    private val temperature: Double? = null,
    private val maxTokens: Int? = null,
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
                throw OpenAICompatibleException.HttpError(status, errBody)
            }
            // `liveCalls[index] = (id, name)` — tool-call fragments carry
            // an `index` and share an `id` only on the first chunk, so we
            // memoize both so subsequent ToolCallArgs emissions reuse the
            // same id the ChatAgent expects.
            val liveCalls = mutableMapOf<Int, Pair<String, String>>()

            BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (!line.startsWith("data: ")) continue
                    val payload = line.removePrefix("data: ")
                    if (payload == "[DONE]") break
                    val chunk = JSONObject(payload)
                    val choices = chunk.optJSONArray("choices") ?: continue
                    if (choices.length() == 0) continue
                    val delta = choices.getJSONObject(0).optJSONObject("delta") ?: continue
                    val text = delta.optString("content", "")
                    if (text.isNotEmpty()) emit(Delta.Text(text))
                    val calls = delta.optJSONArray("tool_calls") ?: continue
                    for (i in 0 until calls.length()) {
                        val tc = calls.getJSONObject(i)
                        val index = tc.optInt("index", i)
                        val fn = tc.optJSONObject("function")
                        val name = fn?.optString("name", "")?.takeIf { it.isNotEmpty() }
                        if (name != null) {
                            val id = tc.optString("id", "tc_$index")
                            liveCalls[index] = id to name
                            emit(Delta.ToolCallStart(id = id, name = name))
                        }
                        val args = fn?.optString("arguments", "")?.takeIf { it.isNotEmpty() }
                        if (args != null) {
                            val (id, _) = liveCalls[index] ?: continue
                            emit(Delta.ToolCallArgs(id = id, argsChunk = args))
                        }
                    }
                }
            }
            emit(Delta.End)
        } finally {
            conn.disconnect()
        }
    }.flowOn(Dispatchers.IO)

    override fun close() { /* URL connections are per-call; nothing persistent. */ }

    // ── HTTP helpers ─────────────────────────────────────────────────────

    private fun httpPost(body: ByteArray, sse: Boolean): String {
        val conn = openConnection(body, sse)
        try {
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else (conn.errorStream ?: conn.inputStream)
            val text = BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).readText()
            if (status !in 200..299) {
                throw OpenAICompatibleException.HttpError(status, text)
            }
            return text
        } finally {
            conn.disconnect()
        }
    }

    private fun openConnection(body: ByteArray, sse: Boolean): HttpURLConnection {
        val url = URL(baseURL.trimEnd('/') + "/chat/completions")
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
        if (!apiKey.isNullOrEmpty()) {
            conn.setRequestProperty("Authorization", "Bearer $apiKey")
        }
        for ((k, v) in extraHeaders) conn.setRequestProperty(k, v)
        conn.outputStream.use { it.write(body) }
        return conn
    }

    // ── Wire encode ──────────────────────────────────────────────────────

    private fun encodeBody(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
        stream: Boolean,
    ): ByteArray {
        val body = JSONObject()
        body.put("model", model)
        body.put("stream", stream)
        body.put("messages", JSONArray(messages.map(::wireMessage)))
        temperature?.let { body.put("temperature", it) }
        maxTokens?.let { body.put("max_tokens", it) }
        if (tools.isNotEmpty()) {
            body.put("tools", JSONArray(tools.map(::wireTool)))
            body.put("tool_choice", "auto")
        }
        return body.toString().toByteArray(Charsets.UTF_8)
    }

    /** Map one [Message] to the OpenAI wire shape. */
    private fun wireMessage(m: Message): JSONObject {
        val o = JSONObject()
        o.put("role", m.role.name)
        o.put("content", m.content)
        if (m.toolCalls.isNotEmpty()) {
            val arr = JSONArray()
            for (tc in m.toolCalls) {
                val call = JSONObject()
                call.put("id", tc.id)
                call.put("type", "function")
                val fn = JSONObject()
                fn.put("name", tc.name)
                // arguments is a raw JSON string in the Dazzle model and
                // OpenAI wants a JSON string too — pass as-is.
                fn.put("arguments", tc.arguments)
                call.put("function", fn)
                arr.put(call)
            }
            o.put("tool_calls", arr)
        }
        m.toolCallId?.let { o.put("tool_call_id", it) }
        return o
    }

    private fun wireTool(d: ToolDeclaration): JSONObject {
        val schemaObj = JSONObject(d.parameters.serialize())
        val fn = JSONObject()
        fn.put("name", d.name)
        fn.put("description", d.description)
        fn.put("parameters", schemaObj)
        val tool = JSONObject()
        tool.put("type", "function")
        tool.put("function", fn)
        return tool
    }

    // ── Non-streaming decode ─────────────────────────────────────────────

    private fun decodeNonStreaming(raw: String): Completion {
        val obj = JSONObject(raw)
        val choices = obj.optJSONArray("choices")
            ?: throw OpenAICompatibleException.EmptyResponse
        if (choices.length() == 0) throw OpenAICompatibleException.EmptyResponse
        val message = choices.getJSONObject(0).optJSONObject("message")
            ?: throw OpenAICompatibleException.EmptyResponse
        val toolCallsArr = message.optJSONArray("tool_calls")
        if (toolCallsArr != null && toolCallsArr.length() > 0) {
            val calls = mutableListOf<ToolCall>()
            for (i in 0 until toolCallsArr.length()) {
                val tc = toolCallsArr.getJSONObject(i)
                val fn = tc.optJSONObject("function")
                calls += ToolCall(
                    id        = tc.optString("id", "tc_$i"),
                    name      = fn?.optString("name", "").orEmpty(),
                    arguments = fn?.optString("arguments", "{}") ?: "{}",
                )
            }
            return Completion.ToolCalls(
                Message(role = Role.assistant, content = "", toolCalls = calls)
            )
        }
        return Completion.Text(
            Message(role = Role.assistant, content = message.optString("content", ""))
        )
    }
}

/** Sealed error class for HTTP-level failures from the adapter. */
sealed class OpenAICompatibleException(msg: String) : RuntimeException(msg) {
    class HttpError(val status: Int, val body: String)
        : OpenAICompatibleException("OpenAI-compatible HTTP $status: $body")
    data object EmptyResponse
        : OpenAICompatibleException("OpenAI-compatible response had no choices")
}
