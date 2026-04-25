// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintStream
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Instrumented tests for [OpenAICompatibleClient]. Spin up a tiny
 * in-process HTTP/1.1 server on a random loopback port, answer
 * canned `chat/completions` payloads, and assert the client
 * produces the expected [Completion] / [Delta] sequence.
 *
 * Keeping the mock server in-test (instead of wiremock / mockwebserver)
 * keeps the instrumented APK small and avoids the classpath friction
 * of adding a new test dep to the Dazzle SDK gradle module.
 */
@RunWith(AndroidJUnit4::class)
class OpenAICompatibleClientInstrumentedTest {

    private lateinit var server: MockHttpServer

    @Before
    fun startServer() {
        server = MockHttpServer().also { it.start() }
    }

    @After
    fun stopServer() {
        server.stop()
    }

    // ── Non-streaming ────────────────────────────────────────────────────

    @Test
    fun completeReturnsTextMessage() = runBlocking {
        server.respondJson(
            """
            {"choices":[{"message":{"role":"assistant","content":"hola, mundo"}}]}
            """.trimIndent()
        )
        val client = client()
        val reply = client.complete(listOf(Message(Role.user, "hi")), emptyList())
        assertTrue(reply is Completion.Text)
        val msg = (reply as Completion.Text).message
        assertEquals(Role.assistant, msg.role)
        assertEquals("hola, mundo", msg.content)
    }

    @Test
    fun completeReturnsToolCalls() = runBlocking {
        server.respondJson(
            """
            {"choices":[{"message":{"role":"assistant","content":null,
            "tool_calls":[{"id":"call_1","type":"function",
            "function":{"name":"weather_get","arguments":"{\"city\":\"Lima\"}"}}]}}]}
            """.trimIndent().replace("\n", "")
        )
        val client = client()
        val reply = client.complete(listOf(Message(Role.user, "weather?")), emptyList())
        assertTrue(reply is Completion.ToolCalls)
        val calls = (reply as Completion.ToolCalls).message.toolCalls
        assertEquals(1, calls.size)
        assertEquals("call_1", calls[0].id)
        assertEquals("weather_get", calls[0].name)
        assertEquals("""{"city":"Lima"}""", calls[0].arguments)
    }

    @Test
    fun completeSendsApiKeyAsBearer() = runBlocking {
        server.respondJson("""{"choices":[{"message":{"role":"assistant","content":"ok"}}]}""")
        val client = OpenAICompatibleClient(
            baseURL = "http://127.0.0.1:${server.port}",
            model = "gpt-4o-mini",
            apiKey = "sk-TEST-123",
        )
        client.complete(listOf(Message(Role.user, "ping")), emptyList())
        val headers = server.lastRequestHeaders()
        assertEquals("Bearer sk-TEST-123", headers["Authorization"])
    }

    @Test
    fun completeSendsModelAndMessagesInBody() = runBlocking {
        server.respondJson("""{"choices":[{"message":{"role":"assistant","content":"ok"}}]}""")
        val client = OpenAICompatibleClient(
            baseURL = "http://127.0.0.1:${server.port}",
            model = "llama-3.3-70b",
        )
        client.complete(
            listOf(
                Message(Role.system, "be brief"),
                Message(Role.user, "hi"),
            ),
            emptyList(),
        )
        val body = JSONObject(server.lastRequestBody())
        assertEquals("llama-3.3-70b", body.getString("model"))
        assertEquals(false, body.getBoolean("stream"))
        val msgs = body.getJSONArray("messages")
        assertEquals(2, msgs.length())
        assertEquals("system", msgs.getJSONObject(0).getString("role"))
        assertEquals("be brief", msgs.getJSONObject(0).getString("content"))
        assertEquals("user", msgs.getJSONObject(1).getString("role"))
    }

    // ── Streaming ────────────────────────────────────────────────────────

    @Test
    fun streamYieldsTextDeltasAndEnd() = runBlocking {
        server.respondSSE(
            listOf(
                """{"choices":[{"delta":{"content":"Hola"}}]}""",
                """{"choices":[{"delta":{"content":", mundo"}}]}""",
                "[DONE]",
            )
        )
        val deltas = client().stream(listOf(Message(Role.user, "hi")), emptyList()).toList()
        val texts = deltas.filterIsInstance<Delta.Text>().joinToString("") { it.chunk }
        assertEquals("Hola, mundo", texts)
        assertTrue("expected trailing Delta.End", deltas.last() == Delta.End)
    }

    @Test
    fun streamYieldsToolCallDeltas() = runBlocking {
        server.respondSSE(
            listOf(
                """{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a",
                "function":{"name":"weather_get"}}]}}]}""".replace("\n", ""),
                """{"choices":[{"delta":{"tool_calls":[{"index":0,
                "function":{"arguments":"{\"city\""}}]}}]}""".replace("\n", ""),
                """{"choices":[{"delta":{"tool_calls":[{"index":0,
                "function":{"arguments":":\"Lima\"}"}}]}}]}""".replace("\n", ""),
                "[DONE]",
            )
        )
        val deltas = client().stream(listOf(Message(Role.user, "w?")), emptyList()).toList()
        val starts = deltas.filterIsInstance<Delta.ToolCallStart>()
        val argsChunks = deltas.filterIsInstance<Delta.ToolCallArgs>().map { it.argsChunk }
        assertEquals(1, starts.size)
        assertEquals("weather_get", starts[0].name)
        assertEquals("call_a", starts[0].id)
        assertEquals("""{"city":"Lima"}""", argsChunks.joinToString(""))
    }

    // ── HTTP errors ──────────────────────────────────────────────────────

    @Test
    fun completeThrowsHttpErrorOn401() {
        server.respondStatus(401, """{"error":{"message":"invalid api key"}}""")
        try {
            runBlocking {
                client().complete(listOf(Message(Role.user, "hi")), emptyList())
            }
            throw AssertionError("expected HttpError")
        } catch (e: OpenAICompatibleException.HttpError) {
            assertEquals(401, e.status)
            assertTrue("error body passes through", e.body.contains("invalid api key"))
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private fun client() = OpenAICompatibleClient(
        baseURL = "http://127.0.0.1:${server.port}",
        model = "gpt-4o-mini",
    )
}

/**
 * Minimal HTTP/1.1 server for tests. One canned response per call;
 * captures the last request headers and body for assertions.
 */
private class MockHttpServer {
    private val socket = ServerSocket(0 /* any free port */)
    val port: Int = socket.localPort

    private var scriptedStatus: Int = 200
    private var scriptedBody: String = "{}"
    private var scriptedSse: List<String>? = null
    private var scriptedContentType: String = "application/json"

    @Volatile private var lastHeaders: Map<String, String> = emptyMap()
    @Volatile private var lastBody: String = ""

    private val loop = thread(name = "mock-http-loop") {
        while (!socket.isClosed) {
            val client = try { socket.accept() } catch (_: Exception) { break }
            thread(name = "mock-http-client") { serve(client) }
        }
    }

    fun respondJson(body: String) {
        scriptedStatus = 200
        scriptedBody = body
        scriptedSse = null
        scriptedContentType = "application/json"
    }

    fun respondSSE(dataFrames: List<String>) {
        scriptedStatus = 200
        scriptedSse = dataFrames
        scriptedContentType = "text/event-stream"
    }

    fun respondStatus(code: Int, body: String) {
        scriptedStatus = code
        scriptedBody = body
        scriptedSse = null
        scriptedContentType = "application/json"
    }

    fun lastRequestHeaders(): Map<String, String> = lastHeaders
    fun lastRequestBody(): String = lastBody

    fun start() { /* thread already started at construction */ }

    fun stop() {
        try { socket.close() } catch (_: Exception) {}
        loop.join(500)
    }

    private fun serve(client: Socket) {
        client.use { c ->
            val reader = BufferedReader(InputStreamReader(c.getInputStream(), Charsets.UTF_8))
            val requestLine = reader.readLine() ?: return
            val headers = mutableMapOf<String, String>()
            var contentLength = 0
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                val idx = line.indexOf(':')
                if (idx <= 0) continue
                val name = line.substring(0, idx).trim()
                val value = line.substring(idx + 1).trim()
                headers[name] = value
                if (name.equals("Content-Length", ignoreCase = true)) {
                    contentLength = value.toInt()
                }
            }
            val bodyChars = CharArray(contentLength)
            if (contentLength > 0) {
                var read = 0
                while (read < contentLength) {
                    val r = reader.read(bodyChars, read, contentLength - read)
                    if (r < 0) break
                    read += r
                }
            }
            lastHeaders = headers
            lastBody = String(bodyChars, 0, bodyChars.size)

            val out = PrintStream(c.getOutputStream(), false, "UTF-8")
            val sse = scriptedSse
            if (sse != null) {
                out.print("HTTP/1.1 $scriptedStatus OK\r\n")
                out.print("Content-Type: $scriptedContentType\r\n")
                out.print("Cache-Control: no-cache\r\n")
                out.print("Connection: close\r\n\r\n")
                for (frame in sse) {
                    out.print("data: $frame\n\n")
                    out.flush()
                }
            } else {
                val body = scriptedBody.toByteArray(Charsets.UTF_8)
                out.print("HTTP/1.1 $scriptedStatus OK\r\n")
                out.print("Content-Type: $scriptedContentType\r\n")
                out.print("Content-Length: ${body.size}\r\n")
                out.print("Connection: close\r\n\r\n")
                out.flush()
                c.getOutputStream().write(body)
            }
            out.flush()
        }
    }
}
