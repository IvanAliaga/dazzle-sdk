// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Android NativeModule that forwards JS calls to the real Dazzle SDK
// (same `dev.dazzle.sdk.DazzleServer` the native Kotlin samples use).

package dev.dazzle.rn

import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import dev.dazzle.sdk.AppendFsync
import dev.dazzle.sdk.DazzleConfig
import dev.dazzle.sdk.DazzleModule
import dev.dazzle.sdk.DazzlePersistence
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.JsonSchema
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.ToolDeclaration
import dev.dazzle.sdk.WipeTarget
import dev.dazzle.sdk.VectorIndex
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.edge.AnthropicClient
import dev.dazzle.sdk.edge.LlamaCppClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class DazzleReactNativeModule(
    private val ctx: ReactApplicationContext
) : ReactContextBaseJavaModule(ctx) {

    private val scope = CoroutineScope(Dispatchers.IO)

    override fun getName() = "DazzleReactNative"

    // ── JSI install ───────────────────────────────────────────────
    //
    // When the module is first accessed from JS, we piggy-back on the
    // bridge's `javaScriptContextHolder` to grab the `jsi::Runtime*`
    // and install `globalThis.__dazzle` — a HostObject that exposes
    // sync, zero-copy entry points for the hot loop
    // (dazzleCommand + the four snap* helpers). The TS shim in
    // src/ffi/command.ts prefers `__dazzle` when present, giving us
    // ~1 µs/call vs ~15 µs on the sync bridge.
    //
    // Safe: if anything goes wrong (library not loaded, runtime not
    // available yet, symbol missing) we silently leave `__dazzle`
    // unbound and the shim falls back to the sync bridge, then the
    // async bridge.
    companion object {
        @JvmStatic private var jsiInstalled = false
        init {
            try { System.loadLibrary("dazzle_rn_jsi") }
            catch (_: Throwable) { /* fall through to sync bridge */ }
        }
    }

    override fun initialize() {
        super.initialize()
        installJsiBinding()
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun installJsi(): Boolean = installJsiBinding()

    private fun installJsiBinding(): Boolean {
        if (jsiInstalled) return true
        return try {
            val holder = ctx.javaScriptContextHolder ?: return false
            val ptr = holder.get()
            if (ptr == 0L) return false
            nativeInstallJsi(ptr)
            jsiInstalled = true
            true
        } catch (_: Throwable) {
            false
        }
    }

    private external fun nativeInstallJsi(runtimePtr: Long)

    // ── Lifecycle ─────────────────────────────────────────────────

    @ReactMethod
    fun start(config: ReadableMap?, promise: Promise) {
        try {
            if (DazzleServer.isRunning()) { promise.resolve(null); return }
            DazzleServer.start(ctx, parseConfig(config))
            promise.resolve(null)
        } catch (t: Throwable) {
            promise.reject("DAZZLE_START_FAILED",
                "${t::class.simpleName}: ${t.message}", t)
        }
    }

    @ReactMethod
    fun stop(promise: Promise) {
        try { if (DazzleServer.isRunning()) DazzleServer.stop(); promise.resolve(null) }
        catch (t: Throwable) { promise.reject("DAZZLE_STOP_FAILED", t) }
    }

    @ReactMethod
    fun isRunning(promise: Promise) {
        promise.resolve(DazzleServer.isRunning())
    }

    @ReactMethod
    fun waitForReady(timeoutMs: Int, promise: Promise) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var ok = DazzleServer.isRunning()
        while (!ok && System.currentTimeMillis() < deadline) {
            Thread.sleep(25)
            ok = DazzleServer.isRunning()
        }
        promise.resolve(ok)
    }

    // ── Commands / snapshot cache fast path ───────────────────────

    @ReactMethod
    fun dazzleCommand(argv: ReadableArray, promise: Promise) {
        scope.launch {
            try {
                val args = Array(argv.size()) { argv.getString(it) ?: "" }
                val reply = DazzleServer.directCommand(*args) ?: ""
                promise.resolve(reply)
            } catch (t: Throwable) {
                promise.reject("DAZZLE_CMD_FAILED", t)
            }
        }
    }

    /**
     * Synchronous hot-path variants. The JS thread blocks until the
     * in-process Valkey event loop replies. Cuts per-call overhead
     * from ~100 µs (async bridge + promise microtask) to ~15 µs —
     * the ~14 µs gap vs the native Kotlin SDK is in the JSON
     * marshalling across the RN bridge.
     *
     * For truly zero-copy, a JSI TurboModule is the next step
     * (tracked in docs/ROADMAP.md). The JS-side dazzleCommand()
     * prefers the sync variant when available.
     */
    @ReactMethod(isBlockingSynchronousMethod = true)
    fun dazzleCommandSync(argv: ReadableArray): String {
        val args = Array(argv.size()) { argv.getString(it) ?: "" }
        return DazzleServer.directCommand(*args) ?: ""
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun snapHGetAllSync(key: String): WritableArray? = try {
        val map = DazzleServer.client().hash(key).getAllDirect()
        if (map.isEmpty()) null else Arguments.createArray().apply {
            for ((k, v) in map) { pushString(k); pushString(v) }
        }
    } catch (_: Throwable) { null }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun snapZRangeByScoreSync(
        key: String, min: Double, max: Double, maxMembers: Int
    ): WritableArray? = try {
        val members = DazzleServer.client().sortedSet(key)
            .rangeByScoreDirect(min, max).take(maxMembers)
        Arguments.createArray().apply { for (m in members) pushString(m) }
    } catch (_: Throwable) { null }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun snapSMembersSync(key: String, maxMembers: Int): WritableArray? = try {
        val members = DazzleServer.client().set(key).membersDirect().take(maxMembers)
        Arguments.createArray().apply { for (m in members) pushString(m) }
    } catch (_: Throwable) { null }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun snapGetSync(key: String): String? = try {
        DazzleServer.client().string(key).getDirect()
    } catch (_: Throwable) { null }

    @ReactMethod
    fun snapHGetAll(key: String, promise: Promise) {
        scope.launch {
            try {
                val h = DazzleServer.client().hash(key)
                val map = h.getAllDirect()
                if (map.isEmpty()) { promise.resolve(null); return@launch }
                val flat = WritableNativeArray()
                for ((k, v) in map) { flat.pushString(k); flat.pushString(v) }
                promise.resolve(flat)
            } catch (t: Throwable) { promise.resolve(null) }
        }
    }

    @ReactMethod
    fun snapZRangeByScore(
        key: String, min: Double, max: Double, maxMembers: Int, promise: Promise
    ) {
        scope.launch {
            try {
                val zs = DazzleServer.client().sortedSet(key)
                // Native side caps to its own hard limit; maxMembers
                // from JS is advisory — slice after the fact.
                val members = zs.rangeByScoreDirect(min, max).take(maxMembers)
                val arr = WritableNativeArray()
                for (m in members) arr.pushString(m)
                promise.resolve(arr)
            } catch (t: Throwable) { promise.resolve(null) }
        }
    }

    @ReactMethod
    fun snapSMembers(key: String, maxMembers: Int, promise: Promise) {
        scope.launch {
            try {
                val s = DazzleServer.client().set(key)
                val members = s.membersDirect().take(maxMembers)
                val arr = WritableNativeArray()
                for (m in members) arr.pushString(m)
                promise.resolve(arr)
            } catch (t: Throwable) { promise.resolve(null) }
        }
    }

    @ReactMethod
    fun snapGet(key: String, promise: Promise) {
        scope.launch {
            try { promise.resolve(DazzleServer.client().string(key).getDirect()) }
            catch (t: Throwable) { promise.resolve(null) }
        }
    }

    // ── Vector index ──────────────────────────────────────────────

    @ReactMethod
    fun vsCreate(opts: ReadableMap, promise: Promise) {
        scope.launch {
            try {
                val name  = opts.getString("name")!!
                val dim   = opts.getInt("dim")
                val m     = if (opts.hasKey("m")) opts.getInt("m") else 32
                val ef    = if (opts.hasKey("ef")) opts.getInt("ef") else 400
                val cap   = if (opts.hasKey("initialCapacity")) opts.getInt("initialCapacity") else 0
                val algo  = opts.getString("algorithm") ?: "hnswSq8"
                val rerank = opts.hasKey("rerank") && opts.getBoolean("rerank")
                val algorithm = when (algo) {
                    "hnswSq8"       -> VectorIndex.Algorithm.HNSW_SQ8
                    "hnswSq8Rerank" -> VectorIndex.Algorithm.HNSW_SQ8_RERANK
                    "hnswF16"       -> VectorIndex.Algorithm.HNSW_F16
                    else            -> VectorIndex.Algorithm.HNSW_SQ8
                }
                val idx = DazzleServer.client().vectorIndex(
                    name = name,
                    hashPrefix = "$name:",
                    vectorField = "emb",
                    dim = dim,
                    algorithm = algorithm,
                    metric = VectorIndex.Metric.COSINE,
                    m = m,
                    efConstruction = ef,
                    initialCapacity = cap,
                )
                idx.create()
                promise.resolve(null)
            } catch (t: Throwable) {
                promise.reject("DAZZLE_VS_CREATE_FAILED", t)
            }
        }
    }

    @ReactMethod
    fun vsAddDirect(name: String, id: String, vector: ReadableArray, promise: Promise) {
        scope.launch {
            try {
                val vec = FloatArray(vector.size()) { vector.getDouble(it).toFloat() }
                val idx = findIndex(name, vec.size)
                idx.addDirect(id, vec)
                promise.resolve(null)
            } catch (t: Throwable) {
                promise.reject("DAZZLE_VS_ADD_FAILED", t)
            }
        }
    }

    @ReactMethod
    fun vsAddBatchDirect(
        name: String, ids: ReadableArray, flat: ReadableArray, dim: Int, promise: Promise
    ) {
        scope.launch {
            try {
                val n = ids.size()
                val idArr = Array(n) { ids.getString(it)!! }
                val vectors = Array(n) { i ->
                    FloatArray(dim) { j -> flat.getDouble(i * dim + j).toFloat() }
                }
                val idx = findIndex(name, dim)
                idx.addBatchDirect(idArr, vectors)
                promise.resolve(null)
            } catch (t: Throwable) {
                promise.reject("DAZZLE_VS_BATCH_FAILED", t)
            }
        }
    }

    @ReactMethod
    fun vsSearchDirect(
        name: String, query: ReadableArray, k: Int, efRuntime: Int, promise: Promise
    ) {
        scope.launch {
            try {
                val dim = query.size()
                val q = FloatArray(dim) { query.getDouble(it).toFloat() }
                val idx = findIndex(name, dim)
                val hits = idx.searchDirect(q, k, efRuntime = efRuntime)
                val out = WritableNativeArray()
                for ((id, distance) in hits) {
                    val row = WritableNativeMap()
                    row.putString("id", id)
                    row.putDouble("distance", distance.toDouble())
                    out.pushMap(row)
                }
                promise.resolve(out)
            } catch (t: Throwable) {
                promise.reject("DAZZLE_VS_SEARCH_FAILED", t)
            }
        }
    }

    private fun findIndex(name: String, dim: Int): VectorIndex =
        DazzleServer.client().vectorIndex(
            name = name,
            hashPrefix = "$name:",
            vectorField = "emb",
            dim = dim,
            algorithm = VectorIndex.Algorithm.HNSW_SQ8,
            metric = VectorIndex.Metric.COSINE,
        )

    // ── LLM bridges (LlamaCpp, LiteRT, FoundationModels) ─────────
    // The MVP ships only the shells — the actual decode loop runs in
    // the native Dazzle SDK. Samples using FakeLLMClient don't touch
    // these, so the e2e harness remains independent of model weights.

    // ── LLM adapter bridges (Llama.cpp + LiteRT-LM) ──────────────
    //
    // Each `create` instantiates a real `LlamaCppClient` /
    // `LiteRtLmClient` (same class the native Kotlin samples use)
    // and stores it under an auto-incrementing handle. Subsequent
    // `generate` calls stream tokens through the RN event bus.
    // `close` disposes.

    private val llamaClients = ConcurrentHashMap<Int, LlamaCppClient>()
    private val nextHandle = AtomicInteger(1)
    private val activeJobs = ConcurrentHashMap<Int, Job>()
    private val llmScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @ReactMethod
    fun llamaCreate(opts: ReadableMap, promise: Promise) {
        llmScope.launch {
            try {
                val modelPath = opts.getString("modelPath")
                    ?: return@launch promise.reject("BAD_ARGS", "modelPath required")
                val systemPrompt = opts.getString("systemPrompt")
                    ?: "You are a helpful on-device AI assistant."
                val temperature = if (opts.hasKey("temperature"))
                    opts.getDouble("temperature").toFloat() else 0.3f
                val maxTokens   = if (opts.hasKey("maxTokens"))
                    opts.getInt("maxTokens") else 512
                val nThreads    = if (opts.hasKey("nThreads"))
                    opts.getInt("nThreads") else 4

                val client = LlamaCppClient(
                    modelFile    = File(modelPath),
                    systemPrompt = systemPrompt,
                    temperature  = temperature,
                    maxTokens    = maxTokens,
                    nThreads     = nThreads,
                )
                val handle = nextHandle.getAndIncrement()
                llamaClients[handle] = client
                promise.resolve(handle)
            } catch (t: Throwable) {
                promise.reject("LLAMA_CREATE_FAILED",
                    "${t::class.simpleName}: ${t.message}", t)
            }
        }
    }

    @ReactMethod
    fun llamaGenerate(opts: ReadableMap, promise: Promise) {
        val handle = opts.getInt("handle")
        val reqId  = opts.getInt("reqId")
        val client = llamaClients[handle]
            ?: return promise.reject("NO_HANDLE", "llama handle $handle not found")
        val messages = decodeMessages(opts.getArray("messages"))
        val tools    = decodeTools(opts.getArray("tools"))

        activeJobs[reqId]?.cancel()
        activeJobs[reqId] = llmScope.launch {
            try {
                client.stream(messages, tools).collect { d ->
                    emitLlama(reqId, deltaToMap(d))
                }
                emitLlama(reqId, mapOf("type" to "end"))
            } catch (t: Throwable) {
                emitLlama(reqId, mapOf("type" to "error",
                    "message" to (t.message ?: t::class.simpleName ?: "error")))
            } finally {
                activeJobs.remove(reqId)
            }
        }
        promise.resolve(null)
    }

    @ReactMethod
    fun llamaClose(handle: Int, promise: Promise) {
        val c = llamaClients.remove(handle)
        llmScope.launch {
            try { c?.close() } catch (_: Throwable) { }
            promise.resolve(null)
        }
    }

    // LiteRT-LM on the RN plugin is opt-in: the official Android
    // runtime (`com.google.ai.edge.litertlm:0.10.0`) was compiled
    // with Kotlin 2.3, while the React Native 0.85 Gradle toolchain
    // still ships Kotlin 2.1 → incompatible Kotlin-module metadata
    // blocks a hard dependency here. Users who need LiteRT on RN
    // today instantiate the native `LiteRtLmClient` themselves in a
    // small shim module. The Flutter plugin takes the same path from
    // a compatible Kotlin toolchain and exposes it end-to-end.
    @ReactMethod
    fun liteRtCreate(opts: ReadableMap, promise: Promise) {
        promise.reject("LITERT_UNAVAILABLE",
            "LiteRtLmClient is opt-in on RN (Kotlin 2.1 vs 2.3 metadata " +
            "conflict with litertlm-android). Use OpenAICompatibleClient or " +
            "LlamaCppClient until the RN Kotlin toolchain catches up.")
    }
    @ReactMethod
    fun liteRtGenerate(opts: ReadableMap, promise: Promise) {
        promise.reject("LITERT_UNAVAILABLE", "opt-in only")
    }
    @ReactMethod
    fun liteRtClose(handle: Int, promise: Promise) { promise.resolve(null) }

    // ── Anthropic (Claude) — `/v1/messages` API ──────────────────
    //
    // Handle-based wrapper around the Kotlin SDK's
    // `dev.dazzle.sdk.edge.AnthropicClient`. Same shape as the llama.cpp
    // bridge above so the JS side gets a uniform contract:
    //   • anthropicCreate({model, apiKey, …}) → handle
    //   • anthropicComplete({handle, messages, tools}) → Map
    //   • anthropicStream({handle, reqId, messages, tools}) → emits
    //                       onAnthropicToken events
    //   • anthropicClose(handle)
    //
    // Streaming events are multiplexed by `reqId` (same trick the
    // LlamaCpp bridge uses) so multiple concurrent streams can coexist.

    private val anthropicClients = ConcurrentHashMap<Int, AnthropicClient>()

    @ReactMethod
    fun anthropicCreate(opts: ReadableMap, promise: Promise) {
        try {
            val model  = opts.getString("model")
                ?: return promise.reject("BAD_ARGS", "model required")
            val apiKey = opts.getString("apiKey")
                ?: return promise.reject("BAD_ARGS", "apiKey required")
            val baseURL = opts.getString("baseURL")
                ?: "https://api.anthropic.com/v1"
            val version = opts.getString("anthropicVersion") ?: "2023-06-01"
            val maxTokens = if (opts.hasKey("maxTokens")) opts.getInt("maxTokens") else 1024
            val temperature = if (opts.hasKey("temperature"))
                opts.getDouble("temperature") else null
            val topP = if (opts.hasKey("topP")) opts.getDouble("topP") else null
            val extraHeaders = mutableMapOf<String, String>()
            if (opts.hasKey("extraHeaders")) {
                opts.getMap("extraHeaders")?.let { m ->
                    val it = m.keySetIterator()
                    while (it.hasNextKey()) {
                        val k = it.nextKey()
                        m.getString(k)?.let { v -> extraHeaders[k] = v }
                    }
                }
            }
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
            anthropicClients[handle] = client
            promise.resolve(handle)
        } catch (t: Throwable) {
            promise.reject("ANTHROPIC_CREATE_FAILED",
                "${t::class.simpleName}: ${t.message}", t)
        }
    }

    @ReactMethod
    fun anthropicComplete(opts: ReadableMap, promise: Promise) {
        val handle = opts.getInt("handle")
        val client = anthropicClients[handle]
            ?: return promise.reject("NO_HANDLE", "anthropic handle $handle not found")
        val messages = decodeMessages(opts.getArray("messages"))
        val tools    = decodeTools(opts.getArray("tools"))
        llmScope.launch {
            try {
                val completion = client.complete(messages, tools)
                val out = Arguments.createMap()
                when (completion) {
                    is Completion.Text -> {
                        out.putString("type", "text")
                        out.putString("content", completion.message.content)
                    }
                    is Completion.ToolCalls -> {
                        out.putString("type", "toolCalls")
                        out.putString("content", completion.message.content)
                        val arr = Arguments.createArray()
                        for (tc in completion.message.toolCalls) {
                            val m = Arguments.createMap()
                            m.putString("id", tc.id)
                            m.putString("name", tc.name)
                            m.putString("arguments", tc.arguments)
                            arr.pushMap(m)
                        }
                        out.putArray("toolCalls", arr)
                    }
                }
                promise.resolve(out)
            } catch (t: Throwable) {
                promise.reject("ANTHROPIC_COMPLETE_FAILED",
                    "${t::class.simpleName}: ${t.message}", t)
            }
        }
    }

    @ReactMethod
    fun anthropicStream(opts: ReadableMap, promise: Promise) {
        val handle = opts.getInt("handle")
        val reqId  = opts.getInt("reqId")
        val client = anthropicClients[handle]
            ?: return promise.reject("NO_HANDLE", "anthropic handle $handle not found")
        val messages = decodeMessages(opts.getArray("messages"))
        val tools    = decodeTools(opts.getArray("tools"))

        activeJobs[reqId]?.cancel()
        activeJobs[reqId] = llmScope.launch {
            try {
                client.stream(messages, tools).collect { d ->
                    emitAnthropic(reqId, deltaToMap(d))
                }
                emitAnthropic(reqId, mapOf("type" to "end"))
            } catch (t: Throwable) {
                emitAnthropic(reqId, mapOf("type" to "error",
                    "message" to (t.message ?: t::class.simpleName ?: "error")))
            } finally {
                activeJobs.remove(reqId)
            }
        }
        promise.resolve(null)
    }

    @ReactMethod
    fun anthropicClose(handle: Int, promise: Promise) {
        val c = anthropicClients.remove(handle)
        llmScope.launch {
            try { c?.close() } catch (_: Throwable) { }
            promise.resolve(null)
        }
    }

    private fun emitAnthropic(reqId: Int, frame: Map<String, Any?>) {
        val body = Arguments.createMap()
        body.putInt("reqId", reqId)
        for ((k, v) in frame) when (v) {
            is String -> body.putString(k, v)
            is Int    -> body.putInt(k, v)
            null      -> body.putNull(k)
            else      -> body.putString(k, v.toString())
        }
        ctx.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("onAnthropicToken", body)
    }

    // ── Decoders shared by the LLM bridges ───────────────────────

    private fun decodeMessages(arr: ReadableArray?): List<Message> {
        if (arr == null) return emptyList()
        val out = mutableListOf<Message>()
        for (i in 0 until arr.size()) {
            val m = arr.getMap(i) ?: continue
            val role = when (m.getString("role")) {
                "system"    -> Role.system
                "assistant" -> Role.assistant
                "tool"      -> Role.tool
                else        -> Role.user
            }
            val content    = m.getString("content") ?: ""
            val toolCallId = m.getString("toolCallId")
            val toolCalls  = mutableListOf<ToolCall>()
            val rawCalls   = if (m.hasKey("toolCalls")) m.getArray("toolCalls") else null
            if (rawCalls != null) for (j in 0 until rawCalls.size()) {
                val c = rawCalls.getMap(j) ?: continue
                toolCalls.add(ToolCall(
                    id        = c.getString("id") ?: continue,
                    name      = c.getString("name") ?: continue,
                    arguments = c.getString("arguments") ?: "{}"))
            }
            out.add(Message(role, content, toolCalls, toolCallId))
        }
        return out
    }

    private fun decodeTools(arr: ReadableArray?): List<ToolDeclaration> {
        if (arr == null) return emptyList()
        val out = mutableListOf<ToolDeclaration>()
        for (i in 0 until arr.size()) {
            val t = arr.getMap(i) ?: continue
            out.add(ToolDeclaration(
                name        = t.getString("name") ?: continue,
                description = t.getString("description") ?: "",
                parameters  = JsonSchema.RawSchema(
                    t.getString("parameters") ?: "{\"type\":\"object\"}")))
        }
        return out
    }

    private fun deltaToMap(d: Delta): Map<String, Any?> = when (d) {
        is Delta.Text          -> mapOf("type" to "text", "chunk" to d.chunk)
        is Delta.ToolCallStart -> mapOf("type" to "toolCallStart",
                                         "id" to d.id, "name" to d.name)
        is Delta.ToolCallArgs  -> mapOf("type" to "toolCallArgs",
                                         "id" to d.id, "chunk" to d.argsChunk)
        Delta.End              -> mapOf("type" to "end")
    }

    private fun emitLlama(reqId: Int, frame: Map<String, Any?>) {
        val body = Arguments.createMap()
        body.putInt("reqId", reqId)
        for ((k, v) in frame) when (v) {
            is String -> body.putString(k, v)
            is Int    -> body.putInt(k, v)
            null      -> body.putNull(k)
            else      -> body.putString(k, v.toString())
        }
        ctx.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
          .emit("onLlamaToken", body)
    }

    // ── Config parsing ────────────────────────────────────────────

    private fun parseConfig(m: ReadableMap?): DazzleConfig {
        if (m == null) return DazzleConfig()
        val port      = if (m.hasKey("port")) m.getInt("port") else 0
        val maxMemory = m.getString("maxMemory") ?: "64mb"
        val modules = if (m.hasKey("modules")) {
            val arr = m.getArray("modules")!!
            val set = mutableSetOf<DazzleModule>()
            for (i in 0 until arr.size()) {
                if (arr.getString(i) == "vectorSearch") set.add(DazzleModule.VectorSearch)
            }
            set
        } else emptySet()
        val wipe = if (m.hasKey("wipeOnStart")) {
            val arr = m.getArray("wipeOnStart")!!
            val set = mutableSetOf<WipeTarget>()
            for (i in 0 until arr.size()) when (arr.getString(i)) {
                "aof" -> set.add(WipeTarget.AOF)
                "rdb" -> set.add(WipeTarget.RDB)
            }
            set
        } else emptySet()
        val persistence = parsePersistence(m.getMap("persistence"))
        return DazzleConfig(
            port = port,
            maxMemory = maxMemory,
            persistence = persistence,
            wipeOnStart = wipe,
            modules = modules,
        )
    }

    private fun parsePersistence(m: ReadableMap?): DazzlePersistence {
        if (m == null) return DazzlePersistence.Aof()
        return when (m.getString("kind")) {
            "none" -> DazzlePersistence.None
            "rdb"  -> DazzlePersistence.Rdb()
            else   -> {
                val fsync = when (m.getString("fsync")) {
                    "always" -> AppendFsync.ALWAYS
                    "no"     -> AppendFsync.NO
                    else     -> AppendFsync.EVERYSEC
                }
                DazzlePersistence.Aof(fsync)
            }
        }
    }

    // Required so addListener/removeListeners don't throw — silences
    // the NativeEventEmitter "Sending events via …" warning.
    @ReactMethod fun addListener(eventName: String) {}
    @ReactMethod fun removeListeners(count: Int) {}

    // ── Sample-test helpers ──────────────────────────────────────
    //
    // Sync env read so the JS-side `isSampleTestMode()` can poll
    // without an extra Promise. The test harness lives in
    // `samples/chat-memory-rn/src/sampleTestRunner.ts` — its shell
    // driver stuffs DAZZLE_SAMPLE_TEST into the system property via
    // `am start --es DAZZLE_SAMPLE_TEST 1` → Activity reads the extra
    // and calls System.setProperty on the MainApplication thread.
    @ReactMethod(isBlockingSynchronousMethod = true)
    fun getEnv(name: String): String? {
        val sysProp = System.getProperty(name)
        if (!sysProp.isNullOrEmpty()) return sysProp
        return System.getenv(name)
    }

    @ReactMethod
    fun writeReport(name: String, json: String, marker: String, promise: Promise) {
        try {
            val dir = ctx.filesDir
            dir.mkdirs()
            java.io.File(dir, "sample_test_${name}.json")
                .writeText(json)
            java.io.File(dir, "experiment_backends_complete.marker")
                .writeText(marker)
            promise.resolve(null)
        } catch (t: Throwable) {
            promise.reject("WRITE_REPORT_FAILED", t)
        }
    }

    /**
     * Shut down the process. Called by the sample-test runner after
     * `writeReport` so the next launch (from the springboard, adb,
     * whatever) starts with a clean slate instead of resuming on the
     * "Sample test completed" screen. Android apps are allowed to
     * `System.exit(0)` — that's how the old `am start -S` flow ends.
     */
    @ReactMethod
    fun exitProcess(promise: Promise) {
        promise.resolve(null)
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            System.exit(0)
        }, 150)
    }
}
