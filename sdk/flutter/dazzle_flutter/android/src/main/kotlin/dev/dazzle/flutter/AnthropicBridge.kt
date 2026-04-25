// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Bridge between Flutter's `AnthropicClient` (Dart) and the native
// `dev.dazzle.sdk.edge.AnthropicClient` the Android SDK ships. Two
// channels:
//
//   MethodChannel  dev.dazzle.flutter/anthropic         — create, close, complete
//   EventChannel   dev.dazzle.flutter/anthropic.tokens  — streaming
//                                                         per generation
//                                                         (args carry
//                                                          handle + msgs)
//
// Same shape as `LiteRtBridge` so anyone reading both files stays
// oriented. Handle-based so the same Dart `AnthropicClient` instance
// is reusable across many turns without re-running the constructor —
// not strictly necessary for HTTP (there's no model to load), but it
// keeps the wire uniform with LiteRT/llama.cpp and lets us hold
// per-instance options (model id, base URL, version, max tokens) on
// the native side.

package dev.dazzle.flutter

import android.os.Handler
import android.os.Looper
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.JsonSchema
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.ToolDeclaration
import dev.dazzle.sdk.edge.AnthropicClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class AnthropicBridge(
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, "dev.dazzle.flutter/anthropic").also {
        it.setMethodCallHandler(this)
    }
    private val events = EventChannel(messenger, "dev.dazzle.flutter/anthropic.tokens").also {
        it.setStreamHandler(this)
    }

    private val nextHandle = AtomicInteger(1)
    private val clients = ConcurrentHashMap<Int, AnthropicClient>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // FlutterEventSink methods are @UiThread — invoking them from
    // Dispatchers.IO crashes with `Methods marked with @UiThread must
    // be executed on the main thread`. We post every sink call
    // through this main-looper handler. The same fix applies to
    // `MethodChannel.Result` callbacks; we use it everywhere.
    private val mainHandler = Handler(Looper.getMainLooper())
    private fun postMain(block: () -> Unit) = mainHandler.post(block)

    // Per-subscription Job tracking — NOT a single `activeJob`.
    //
    // When turn N's dart-side subscription closes, Flutter posts an
    // async `onCancel` to the platform thread. If the agent issues
    // turn N+1 immediately, that turn's `onListen` lands BEFORE the
    // late `onCancel` does. With a single `activeJob`, the late
    // `onCancel` cancels turn N+1's HTTP coroutine — empty reply.
    //
    // Fix: dict keyed by sub-id, `onCancel` is a no-op (jobs
    // self-deregister when done), `dispose()` cancels everything.
    private val jobsBySubId = ConcurrentHashMap<Int, Job>()
    private val nextSubId = AtomicInteger(0)

    fun dispose() {
        scope.cancel()
        jobsBySubId.values.forEach { it.cancel() }
        jobsBySubId.clear()
        clients.values.forEach { try { it.close() } catch (_: Throwable) {} }
        clients.clear()
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    // MethodChannel — `create`, `close`, `complete`.

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create"   -> doCreate(call, result)
            "close"    -> doClose(call, result)
            "complete" -> doComplete(call, result)
            else       -> result.notImplemented()
        }
    }

    private fun doCreate(call: MethodCall, result: MethodChannel.Result) {
        try {
            val model     = call.argument<String>("model")
                ?: throw IllegalArgumentException("model is required")
            val apiKey    = call.argument<String>("apiKey")
                ?: throw IllegalArgumentException("apiKey is required")
            val baseURL   = call.argument<String>("baseURL")
                ?: "https://api.anthropic.com/v1"
            val version   = call.argument<String>("anthropicVersion") ?: "2023-06-01"
            val maxTokens = call.argument<Int>("maxTokens") ?: 1024
            val temperature = (call.argument<Number>("temperature"))?.toDouble()
            val topP        = (call.argument<Number>("topP"))?.toDouble()
            val extraHeaders = (call.argument<Map<String, Any?>>("extraHeaders"))
                ?.mapValues { it.value?.toString() ?: "" }
                ?.filterValues { it.isNotEmpty() }
                ?: emptyMap()

            val client = AnthropicClient(
                model = model,
                apiKey = apiKey,
                baseURL = baseURL,
                anthropicVersion = version,
                maxTokens = maxTokens,
                temperature = temperature,
                topP = topP,
                extraHeaders = extraHeaders,
            )
            val handle = nextHandle.getAndIncrement()
            clients[handle] = client
            result.success(handle)
        } catch (t: Throwable) {
            result.error("ANTHROPIC_CREATE_FAILED",
                "${t::class.simpleName}: ${t.message}", null)
        }
    }

    private fun doClose(call: MethodCall, result: MethodChannel.Result) {
        val handle = call.argument<Int>("handle") ?: return result.success(null)
        val client = clients.remove(handle) ?: return result.success(null)
        try { client.close() } catch (_: Throwable) {}
        result.success(null)
    }

    private fun doComplete(call: MethodCall, result: MethodChannel.Result) {
        val handle = call.argument<Int>("handle")
        val client = handle?.let { clients[it] }
        if (client == null) {
            result.error("NO_HANDLE", "handle $handle not found", null); return
        }
        val messages = decodeMessages(call.argument("messages"))
        val tools    = decodeTools(call.argument("tools"))
        scope.launch {
            try {
                val completion = client.complete(messages, tools)
                postMain { result.success(encodeCompletion(completion)) }
            } catch (t: Throwable) {
                postMain {
                    result.error("ANTHROPIC_COMPLETE_FAILED",
                        "${t::class.simpleName}: ${t.message}", null)
                }
            }
        }
    }

    // EventChannel — each `onListen` invocation is one generation request.
    //
    // args = {
    //   'handle': Int,
    //   'messages': [{ role, content, toolCallId?, toolCalls? }, …],
    //   'tools':    [{ name, description, parameters }, …],
    // }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val sink = events ?: return
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?>
        if (args == null) { sink.error("BAD_ARGS", "no arguments", null); return }

        val handle = args["handle"] as? Int
        val client = handle?.let { clients[it] }
        if (client == null) {
            sink.error("NO_HANDLE", "handle $handle not found", null); return
        }

        val messages = decodeMessages(args["messages"])
        val tools    = decodeTools(args["tools"])
        // streamId cookie — the dart-side shim drops frames whose
        // streamId doesn't match the cookie it asked for. Defends
        // against EventChannel buffer replay between turns.
        val streamId = (args["streamId"] as? Int) ?: 0

        val mySubId = nextSubId.incrementAndGet()
        val job = scope.launch {
            try {
                client.stream(messages, tools).collect { d ->
                    val frame: Map<String, Any?> = when (d) {
                        is Delta.Text          -> mapOf("type" to "text",
                            "chunk" to d.chunk, "streamId" to streamId)
                        is Delta.ToolCallStart -> mapOf("type" to "toolCallStart",
                            "id" to d.id, "name" to d.name, "streamId" to streamId)
                        is Delta.ToolCallArgs  -> mapOf("type" to "toolCallArgs",
                            "id" to d.id, "chunk" to d.argsChunk, "streamId" to streamId)
                        Delta.End              -> mapOf("type" to "end",
                            "streamId" to streamId)
                    }
                    postMain { sink.success(frame) }
                }
                // Send `type:"end"` so the dart-side StreamController
                // closes; do NOT call `sink.endOfStream()` — that
                // permanently kills the EventChannel and every future
                // `onListen` sees no events.
                postMain {
                    sink.success(mapOf("type" to "end", "streamId" to streamId))
                }
            } catch (t: Throwable) {
                postMain {
                    sink.error("ANTHROPIC_STREAM_FAILED",
                        "${t::class.simpleName}: ${t.message}", null)
                }
            } finally {
                jobsBySubId.remove(mySubId)
            }
        }
        jobsBySubId[mySubId] = job
    }

    override fun onCancel(arguments: Any?) {
        // Intentionally a no-op — see the comment above
        // `jobsBySubId`. The previous turn's `onCancel` lands
        // asynchronously and would otherwise cancel the next
        // turn's coroutine. Jobs self-deregister on completion;
        // `dispose()` cancels anything still in-flight.
    }

    // ── Wire decoding ────────────────────────────────────────────────────

    private fun decodeMessages(raw: Any?): List<Message> {
        val arr = raw as? List<*> ?: return emptyList()
        return arr.mapNotNull { el ->
            @Suppress("UNCHECKED_CAST")
            val m = el as? Map<String, Any?> ?: return@mapNotNull null
            val role = when (m["role"] as? String) {
                "system"    -> Role.system
                "assistant" -> Role.assistant
                "tool"      -> Role.tool
                else        -> Role.user
            }
            val content = (m["content"] as? String) ?: ""
            val toolCallId = m["toolCallId"] as? String
            val toolCalls  = (m["toolCalls"] as? List<*>)?.mapNotNull { c ->
                @Suppress("UNCHECKED_CAST")
                val cm = c as? Map<String, Any?> ?: return@mapNotNull null
                ToolCall(
                    id        = cm["id"]        as? String ?: return@mapNotNull null,
                    name      = cm["name"]      as? String ?: return@mapNotNull null,
                    arguments = cm["arguments"] as? String ?: "{}",
                )
            } ?: emptyList()
            Message(role, content, toolCalls, toolCallId)
        }
    }

    private fun decodeTools(raw: Any?): List<ToolDeclaration> {
        val arr = raw as? List<*> ?: return emptyList()
        return arr.mapNotNull { el ->
            @Suppress("UNCHECKED_CAST")
            val t = el as? Map<String, Any?> ?: return@mapNotNull null
            ToolDeclaration(
                name        = t["name"]        as? String ?: return@mapNotNull null,
                description = t["description"] as? String ?: "",
                parameters  = JsonSchema.RawSchema(
                    t["parameters"] as? String ?: "{\"type\":\"object\"}"),
            )
        }
    }

    private fun encodeCompletion(c: Completion): Map<String, Any?> {
        return when (c) {
            is Completion.Text -> mapOf(
                "type" to "text",
                "content" to c.message.content,
            )
            is Completion.ToolCalls -> mapOf(
                "type" to "toolCalls",
                "content" to c.message.content,
                "toolCalls" to c.message.toolCalls.map {
                    mapOf("id" to it.id, "name" to it.name, "arguments" to it.arguments)
                },
            )
        }
    }
}
