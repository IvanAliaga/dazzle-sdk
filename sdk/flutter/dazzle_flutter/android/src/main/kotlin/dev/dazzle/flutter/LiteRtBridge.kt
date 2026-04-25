// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Bridge between Flutter's LiteRtLmClient (Dart) and the native
// `dev.dazzle.sdk.edge.LiteRtLmClient` the Android SDK ships. Two
// channels:
//
//   MethodChannel  dev.dazzle.flutter/litertlm        — create, close
//   EventChannel   dev.dazzle.flutter/litertlm.tokens — streaming
//                                                       per generation
//                                                       (args carry
//                                                        handle + msgs)
//
// Each `create` instantiates a native client and stores it under an
// auto-incrementing int handle. Subsequent `stream` requests re-use
// that handle; `close` disposes it. Several concurrent streams are
// allowed — Google's Engine is reentrant behind an internal mutex.

package dev.dazzle.flutter

import android.content.Context
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.ToolDeclaration
import dev.dazzle.sdk.JsonSchema
import dev.dazzle.sdk.edge.LiteRtLmClient
import dev.dazzle.sdk.edge.ToolCallSyntax
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
import java.io.File
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class LiteRtBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, "dev.dazzle.flutter/litertlm").also {
        it.setMethodCallHandler(this)
    }
    private val events = EventChannel(messenger, "dev.dazzle.flutter/litertlm.tokens").also {
        it.setStreamHandler(this)
    }

    private val nextHandle = AtomicInteger(1)
    private val clients = ConcurrentHashMap<Int, LiteRtLmClient>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Same EventChannel hardening pattern as AnthropicBridge.kt:
    //   * `mainHandler` posts every sink call to the UI thread
    //     (`FlutterEventSink` is `@UiThread`).
    //   * `jobsBySubId` tracks per-subscription coroutines so a
    //     late `onCancel` from turn N doesn't kill turn N+1's job.
    //   * Outbound frames carry a `streamId` cookie — the dart-side
    //     shim drops residuals from earlier subscriptions that
    //     Flutter's EventChannel buffer occasionally replays.
    //   * On natural completion we send `{"type":"end"}` only;
    //     never `sink.endOfStream()` (it permanently kills the
    //     channel for every future turn).
    private val mainHandler = Handler(Looper.getMainLooper())
    private fun postMain(block: () -> Unit) = mainHandler.post(block)
    private val jobsBySubId = ConcurrentHashMap<Int, Job>()
    private val nextSubId = AtomicInteger(0)

    fun dispose() {
        scope.cancel()
        jobsBySubId.values.forEach { it.cancel() }
        jobsBySubId.clear()
        clients.values.forEach { /* LiteRtLmClient.close is idempotent */ try { it.close() } catch (_: Throwable) {} }
        clients.clear()
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    // MethodChannel — `create`, `close`.

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> doCreate(call, result)
            "close"  -> doClose(call, result)
            else     -> result.notImplemented()
        }
    }

    private fun doCreate(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val modelPath    = call.argument<String>("modelPath")
                    ?: throw IllegalArgumentException("modelPath is required")
                val systemPrompt = call.argument<String>("systemPrompt")
                    ?: "You are a helpful on-device AI assistant."
                val temperature  = (call.argument<Number>("temperature") ?: 0.01).toDouble()
                val maxTokens    = call.argument<Int>("maxTokens") ?: 512

                val client = LiteRtLmClient(
                    modelFile    = File(modelPath),
                    context      = context,
                    systemPrompt = systemPrompt,
                    temperature  = temperature,
                    maxTokens    = maxTokens,
                )
                val handle = nextHandle.getAndIncrement()
                clients[handle] = client
                result.success(handle)
            } catch (t: Throwable) {
                result.error("LITERT_CREATE_FAILED",
                    "${t::class.simpleName}: ${t.message}", null)
            }
        }
    }

    private fun doClose(call: MethodCall, result: MethodChannel.Result) {
        val handle = call.argument<Int>("handle") ?: return result.success(null)
        val client = clients.remove(handle) ?: return result.success(null)
        scope.launch {
            try { client.close() } catch (_: Throwable) { }
            result.success(null)
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
                postMain {
                    sink.success(mapOf("type" to "end", "streamId" to streamId))
                }
            } catch (t: Throwable) {
                postMain {
                    sink.error("LITERT_STREAM_FAILED",
                        "${t::class.simpleName}: ${t.message}", null)
                }
            } finally {
                jobsBySubId.remove(mySubId)
            }
        }
        jobsBySubId[mySubId] = job
    }

    override fun onCancel(arguments: Any?) {
        // Intentionally a no-op — see the comment near `jobsBySubId`.
        // Flutter's `onCancel` lands asynchronously and frequently
        // arrives AFTER the next turn's `onListen`, so cancelling
        // here would kill the new turn's coroutine. Jobs
        // self-deregister; `dispose()` handles plugin-detach cleanup.
    }

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
            // The Dart side serialises parameters as a JSON string. The
            // native LiteRtLmClient accepts a `ToolDeclaration` that
            // holds its own JsonSchema object, but for the cross-
            // platform bridge we keep parameters as the string and
            // build a ToolDeclaration directly.
            ToolDeclaration(
                name        = t["name"]        as? String ?: return@mapNotNull null,
                description = t["description"] as? String ?: "",
                parameters  = JsonSchema.RawSchema(
                    t["parameters"] as? String ?: "{\"type\":\"object\"}"),
            )
        }
    }
}
