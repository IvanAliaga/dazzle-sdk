// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Android side of the dazzle_flutter plugin.
//
// Responsibilities:
//   1. Register the `dev.dazzle.flutter` method channel so the Dart
//      `DazzleServer` can drive the embedded Valkey server's lifecycle
//      (start, stop, waitForReady, isRunning).
//   2. Forward those calls to the real Dazzle SDK's `DazzleServer`
//      object — the same one native Kotlin apps use.
//
// All DATA operations (HSET/HGETALL/ZADD/FT.SEARCH/…) skip this plugin
// entirely and go directly from Dart dart:ffi → libdazzle.so → the
// in-process transport. The method channel exists only for the
// lifecycle ceremony.

package dev.dazzle.flutter

import android.content.Context
import dev.dazzle.sdk.AppendFsync
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.WipeTarget
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class DazzleFlutterPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var liteRtBridge: LiteRtBridge? = null
    private var anthropicBridge: AnthropicBridge? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.dazzle.flutter")
        channel.setMethodCallHandler(this)
        // LiteRT-LM bridge — sits on its own method + event channels.
        // Dead code unless the consumer actually adds the
        // `com.google.ai.edge.litertlm:litertlm-android` runtime to
        // their app module — the bridge class resolves at first
        // `create` call, and LiteRtLmClient's init fails early with
        // a clear message if the runtime is missing.
        liteRtBridge = LiteRtBridge(context, binding.binaryMessenger)
        // Anthropic bridge — also dormant until the Dart-side
        // `AnthropicClient` constructor runs `create` on it. No
        // runtime deps; uses the Kotlin SDK's `AnthropicClient`
        // (HttpURLConnection + org.json, zero external libs).
        anthropicBridge = AnthropicBridge(binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        liteRtBridge?.dispose()
        liteRtBridge = null
        anthropicBridge?.dispose()
        anthropicBridge = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> handleStart(call, result)
            "stop" -> {
                if (DazzleServer.isRunning()) DazzleServer.stop()
                result.success(null)
            }
            "waitForReady" -> {
                // DazzleServer.start() is synchronous on JVM — once it
                // returns, the server is ready. For parity with the
                // Dart-side API we still spin-poll isRunning() until
                // the given deadline.
                val timeoutMs = (call.argument<Int>("timeoutMs") ?: 5000).toLong()
                val deadline = System.currentTimeMillis() + timeoutMs
                var ok = DazzleServer.isRunning()
                while (!ok && System.currentTimeMillis() < deadline) {
                    Thread.sleep(25)
                    ok = DazzleServer.isRunning()
                }
                result.success(ok)
            }
            "isRunning" -> result.success(DazzleServer.isRunning())
            else -> result.notImplemented()
        }
    }

    /**
     * Parse the DazzleConfig map the Dart side sent and boot the server
     * exactly as a native Kotlin caller would. Idempotent — calling
     * `start` when the server is already running is a no-op.
     */
    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (DazzleServer.isRunning()) {
                result.success(null)
                return
            }
            @Suppress("UNCHECKED_CAST")
            val m = (call.arguments as Map<String, Any?>?)
            val cfg = parseConfig(m)
            DazzleServer.start(context, cfg)
            result.success(null)
        } catch (t: Throwable) {
            result.error("DAZZLE_START_FAILED",
                "${t::class.simpleName}: ${t.message}", null)
        }
    }

    private fun parseConfig(m: Map<String, Any?>?): DazzleConfig {
        if (m == null) return DazzleConfig()

        val port      = (m["port"] as? Int) ?: 0
        val maxMemory = (m["maxMemory"] as? String) ?: "64mb"
        val modules   = (m["modules"] as? List<*>)
            ?.mapNotNull { name ->
                when (name) {
                    "vectorSearch" -> DazzleModule.VectorSearch
                    else -> null
                }
            }?.toSet() ?: emptySet()
        val wipeOnStart = (m["wipeOnStart"] as? List<*>)
            ?.mapNotNull { name ->
                when (name) {
                    "aof" -> WipeTarget.AOF
                    "rdb" -> WipeTarget.RDB
                    else  -> null
                }
            }?.toSet() ?: emptySet()

        val persistence = parsePersistence(
            m["persistence"] as? Map<*, *>
        )

        return DazzleConfig(
            port        = port,
            maxMemory   = maxMemory,
            persistence = persistence,
            wipeOnStart = wipeOnStart,
            modules     = modules,
        )
    }

    private fun parsePersistence(m: Map<*, *>?): DazzlePersistence {
        if (m == null) return DazzlePersistence.Aof()
        return when (m["kind"]) {
            "none" -> DazzlePersistence.None
            "rdb"  -> DazzlePersistence.Rdb()  // Saves list passed through separately by users who need it.
            else -> {
                val fsync = when (m["fsync"] as? String) {
                    "always"   -> AppendFsync.ALWAYS
                    "no"       -> AppendFsync.NO
                    else       -> AppendFsync.EVERYSEC
                }
                DazzlePersistence.Aof(fsync)
            }
        }
    }
}
