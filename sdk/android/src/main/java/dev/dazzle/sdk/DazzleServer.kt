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
// See the License for the specific language governing permissions and
// limitations under the License.

package dev.dazzle.sdk

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Embedded Valkey server — in-process, bound to loopback (or direct-only),
 * configured through a typed [DazzleConfig].
 *
 * ## Quick start
 *
 * ```kotlin
 * // Default: durable AOF, loopback TCP on 6379 with fallback
 * DazzleServer.start(context)
 *
 * // Experiment: no persistence, wipe leftovers, dedicated port
 * DazzleServer.start(context, DazzleConfig(
 *     port        = 6380,
 *     persistence = DazzlePersistence.None,
 *     wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
 * ))
 *
 * // Low-level single command (variadic — values with spaces are OK)
 * DazzleServer.directCommand("HSET", "agent:decisions", "0", "no anomaly")
 * DazzleServer.directCommand("XADD", "sensor:readings", "*", "temp", "22.3")
 *
 * // Batched in-process writes (single round-trip through the event loop)
 * DazzleServer.directPipeline(listOf(
 *     listOf("HINCRBYFLOAT", "sensor:stats", "temp_sum", "22.3"),
 *     listOf("HINCRBY",      "sensor:stats", "count", "1"),
 * ))
 * ```
 *
 * ## Three command paths, explicit semantics
 *
 * | Method                  | Transport                 | Use for |
 * | ----------------------- | ------------------------- | ------- |
 * | [directCommand]         | in-process pipe           | writes and simple reads |
 * | [directPipeline]        | in-process pipe (batched) | hot write loops |
 * | [command]               | persistent TCP loopback   | multi-bulk reads (XRANGE, ZRANGE, LRANGE) |
 *
 * The first two go through the JNI direct path and return a single parsed
 * RESP string per command. The TCP path uses a standard RESP parser and
 * is required for commands that return arrays the direct parser can't
 * flatten into a single string.
 *
 * Thread safety: every method is safe to call from any thread. Internally
 * the library serializes direct commands on Valkey's event loop via a
 * pipe, and the TCP path is protected by a mutex around a single
 * persistent socket. Consumers should NOT call these methods from the
 * Android main thread — dispatch them to `Dispatchers.IO` or a background
 * thread of their choice.
 */
object DazzleServer {

    private const val TAG = "DazzleServer"

    private var currentConfig: DazzleConfig? = null

    /** The active [DazzleConfig], or the default if the server is not running. */
    val config: DazzleConfig get() = currentConfig ?: DazzleConfig()
    private var currentDataDir: File? = null
    private var currentPort: Int = DazzleConfig.DEFAULT_PORT
    private var logger: DazzleLogger = DazzleLogger.DEFAULT
    private var metrics: DazzleMetrics = DazzleMetrics.DEFAULT

    init {
        System.loadLibrary("dazzle")
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    /**
     * Start the embedded server with the given [config]. No-op if the
     * server is already running.
     *
     * @throws DazzleException.PortInUse     preferred port is in use and
     *         [DazzleConfig.allowPortFallback] is false
     * @throws DazzleException.NoFreePort    every port in the fallback
     *         range is in use
     * @throws DazzleException.ModuleUnavailable a requested module's `.so`
     *         is not packaged in this build
     * @throws DazzleException.StartFailed   native start returned false
     */
    @JvmOverloads
    fun start(context: Context, config: DazzleConfig = DazzleConfig()) {
        if (isRunning()) return

        logger = config.logger
        metrics = config.metrics

        val dataDir = (config.dataDir ?: File(context.filesDir, "valkey")).apply { mkdirs() }

        // ── Pre-start cleanup ──
        if (config.wipeOnStart.isNotEmpty()) {
            wipeDataDir(dataDir, config.wipeOnStart)
        }

        // ── Resolve modules ──
        // Statically linked modules (valkey-search, TFI) are compiled into
        // libdazzle.so and loaded by passing --loadmodule @static:<name> at
        // startup. Valkey's patched module.c uses dlopen(RTLD_DEFAULT) on
        // that token so dlsym finds ValkeyModule_OnLoad_<name> already
        // resident in the process. Only .custom(file) still needs a real
        // filesystem path. Lua is core-integrated in Valkey 9 and contributes
        // no --loadmodule flag.
        for (mod in config.modules) {
            if (!mod.isShipped) throw DazzleException.ModuleUnavailable(mod, mod.label)
        }
        val modulePaths = config.modules.mapNotNull { mod -> mod.staticModulePath }

        // ── Pick port (if TCP enabled) ──
        val portToUse = if (config.tcpEnabled) {
            pickFreePort(config.port, config.portRange, config.allowPortFallback)
        } else {
            0   // --port 0 disables the TCP listener in Valkey
        }

        // ── Write minimal valkey.conf from assets (for settings the CLI
        //     args do NOT cover — memory limits, hz, listpack thresholds). ──
        val configFile = extractConfig(context, dataDir)

        // ── Apply ExecutionPolicy ──
        // Parallel read worker pool is enabled via env var DAZZLE_PARALLEL_READS
        // (read by dazzle_worker_pool.c at server startup). Setting it BEFORE
        // nativeStart() is critical — the worker_pool reads env on boot.
        // IO threads flow through CLI args in buildCliArgs() below.
        val effectiveWorkers = config.execution.effectiveReadWorkers(
            Runtime.getRuntime().availableProcessors()
        )
        if (effectiveWorkers > 0) {
            nativeSetEnv("DAZZLE_PARALLEL_READS", "1")
            nativeSetEnv("DAZZLE_WORKER_POOL_SIZE", effectiveWorkers.toString())
        } else {
            nativeSetEnv("DAZZLE_PARALLEL_READS", "0")
        }

        // ── Translate typed config → CLI args ──
        val cliArgs = buildCliArgs(
            configFile = configFile,
            dataDir    = dataDir,
            port       = portToUse,
            modulePaths = modulePaths,
            config     = config,
        )

        logger.info(TAG,
            "starting: port=$portToUse persistence=${config.persistence::class.simpleName} " +
            "modules=[${config.modules.joinToString { it.label }}] " +
            "execution=[readWorkers=$effectiveWorkers ioThreads=${config.execution.ioThreads}] " +
            "dataDir=${dataDir.absolutePath}"
        )

        val ok = nativeStart(cliArgs)
        if (!ok) {
            throw DazzleException.StartFailed(
                "native start returned false — inspect ${File(dataDir, "valkey.log").absolutePath}"
            )
        }

        currentConfig = config
        currentDataDir = dataDir
        currentPort = portToUse
    }

    /** Backward-compat shim for callers written against the old signature. */
    @Deprecated(
        "Use start(context, DazzleConfig(port = ..., maxMemory = ...)) instead.",
        ReplaceWith("start(context, DazzleConfig(port = port, maxMemory = maxMemory))")
    )
    fun start(context: Context, port: Int = DazzleConfig.DEFAULT_PORT, maxMemory: String = "64mb") {
        start(context, DazzleConfig(port = port, maxMemory = maxMemory))
    }

    /**
     * Gracefully stop the server via SHUTDOWN command (no SIGTERM).
     * Safe to call from any thread. Data is persisted according to the
     * configured [DazzlePersistence] mode.
     */
    fun stop() {
        if (!isRunning()) return
        nativeStop()
        currentConfig = null
        currentDataDir = null
    }

    /**
     * Stop the server (if running), wipe the requested artifacts from
     * the data directory, and restart with the same [DazzleConfig].
     *
     * Useful for tests and experiments that want to clear state between
     * cases without tearing down the app process.
     */
    @JvmOverloads
    fun reset(context: Context, wipe: Set<WipeTarget> = WipeTarget.ALL) {
        val cfg = currentConfig ?: DazzleConfig()
        val wasRunning = isRunning()
        if (wasRunning) stop()

        val dir = currentDataDir ?: (cfg.dataDir ?: File(context.filesDir, "valkey"))
        wipeDataDir(dir, wipe)

        if (wasRunning) start(context, cfg)
    }

    fun isRunning(): Boolean = nativeIsRunning()

    /** The TCP port the running server is bound to. Zero if [DazzleConfig.tcpEnabled] was false. */
    fun getPort(): Int = currentPort

    // ── Direct command path (in-process, lowest latency) ─────────────────

    /**
     * Execute one command through the in-process JNI pipe. Variadic:
     * each argument is passed as-is without string splitting, so values
     * with spaces are safe.
     *
     * Returns the parsed RESP reply as a string, or `null` if the server
     * is not running. For commands that naturally return arrays (XRANGE,
     * ZRANGE, LRANGE, KEYS, SMEMBERS …) use [command] instead — this path
     * flattens multi-bulk replies into a single concatenated string.
     */
    fun directCommand(vararg args: String): String? {
        if (!isRunning() || args.isEmpty()) return null
        val start = System.nanoTime()
        @Suppress("UNCHECKED_CAST")
        val raw = nativeDirectCommand(args as Array<String>)
        metrics.commandExecuted(
            command     = args[0].uppercase(),
            argc        = args.size,
            latencyNanos = System.nanoTime() - start,
            success     = raw != null,
        )
        return raw
    }

    /**
     * Direct read-only path that bypasses the event-loop pipe entirely.
     * Uses a rwlock to access Valkey's internal data structures from the
     * caller thread — ~6× faster than [directCommand] for supported
     * read commands (HMGET, HGET).
     *
     * Falls back to [directCommand] for unsupported commands (the native
     * layer returns null for commands it doesn't handle directly).
     */
    fun directRead(vararg args: String): String? {
        if (!isRunning() || args.isEmpty()) return null
        val start = System.nanoTime()
        @Suppress("UNCHECKED_CAST")
        val raw = nativeDirectRead(args as Array<String>)
            ?: return directCommand(*args)  // fallback for unsupported commands
        metrics.commandExecuted(
            command     = args[0].uppercase() + "_DIRECT",
            argc        = args.size,
            latencyNanos = System.nanoTime() - start,
            success     = true,
        )
        return raw
    }

    /**
     * Phase 5 (partial): HMGET bypassing RESP entirely.
     *
     * Returns a `String?[]` where each element is the field value, or null
     * if the field was not found in the snapshot.  Returns null itself if
     * the key is not yet cached (caller should fall back to [directRead]).
     *
     * Saves ~100 µs vs the RESP path by eliminating:
     *   - snprintf × N (build RESP in C)
     *   - NewStringUTF × 1 (large RESP string)
     *   - Kotlin RESP tokenizer (~80 µs for 6 fields)
     */
    fun directReadFields(key: String, vararg fields: String): Array<String?>? {
        if (!isRunning()) return null
        @Suppress("UNCHECKED_CAST")
        return nativeDirectReadFields(key, fields as Array<String>)
    }

    /**
     * Single-field typed fast path — returns the one field value directly
     * as a [String], skipping the vararg + Array<String?> machinery of
     * [directReadFields]. Ideal for materialised-view reads that only
     * consume one precomputed blob (e.g. a pre-rendered context block).
     *
     * Returns null on snapshot miss OR when the field is absent — callers
     * that need to distinguish the two cases should use [directReadFields].
     */
    fun directReadField(key: String, field: String): String? {
        if (!isRunning()) return null
        return nativeDirectReadField(key, field)
    }

    /**
     * Phase 7 typed HGETALL — reads every (field, value) pair stored for
     * [key] in the snapshot cache without generating or parsing RESP.
     *
     * Returns null when the key is not yet cached (caller should fall back
     * to the pipe-path HGETALL) or a flat `String[]` laid out interleaved
     * `[k0, v0, k1, v1, …]`. The caller converts to a map in Kotlin land
     * without paying the RESP encode + `RespParser.parse(array)` cost.
     *
     * Motivation — ContextStore.get() invokes HashKey.getAll() which today
     * runs through commandTyped(HGETALL). Valkey RESP-encodes the
     * multi-bulk, the pipe copies a potentially large string, and
     * RespParser walks it in Kotlin. Every step is waste when the record
     * is already in the snapshot: we have the (k, v) pairs in memory,
     * just hand them over.
     */
    fun directHgetall(key: String): Array<String?>? {
        if (!isRunning()) return null
        return nativeDirectHgetall(key)
    }

    /**
     * Phase 2 typed SMEMBERS — reads set members stored in the snapshot
     * cache without the RESP round-trip. Null on snapshot miss or
     * wrong-type entry; caller falls back to the standard
     * `set(key).members()` path.
     *
     * Used by ContextStore.byTag / byTags to iterate tag indexes in hot
     * loops without paying the RESP cost for every lookup.
     */
    fun directSmembers(key: String): Array<String?>? {
        if (!isRunning()) return null
        return nativeDirectSmembers(key)
    }

    /**
     * Phase 2 typed ZRANGEBYSCORE — emits members whose score lies in
     * `[min, max]` (both inclusive), ascending by score. Null on
     * snapshot miss or wrong-type entry.
     *
     * Used by ContextStore.byTimeRange to pull id ranges without
     * touching the Valkey event loop when the time index is hot.
     */
    fun directZrangeByScore(key: String, min: Double, max: Double): Array<String?>? {
        if (!isRunning()) return null
        return nativeDirectZrangeByScore(key, min, max)
    }

    /**
     * Phase 2 typed GET for string keys. Returns the value on snapshot
     * hit or null on miss / wrong type. The caller should fall back to
     * the pipe-path GET when null.
     */
    fun directGetString(key: String): String? {
        if (!isRunning()) return null
        return nativeDirectGetString(key)
    }

    /**
     * Phase 6a — multi-key typed snapshot HMGET. Reads N hash keys in a
     * single JNI crossing under one snapshot rwlock.
     *
     * Semantics:
     *   - whole return is null → every key missed the snapshot (caller
     *     falls back to the pipe for each).
     *   - row is null         → that key missed (caller falls back for it).
     *   - row[j] is null      → field is absent in the cached hash.
     *
     * Falls back to [directReadFields] for single-request batches so
     * callers get the same fast path whether they pass 1 or N requests.
     */
    fun directReadMFields(
        requests: List<Pair<String, List<String>>>
    ): Array<Array<String?>?>? {
        if (!isRunning() || requests.isEmpty()) return null
        if (requests.size == 1) {
            val (k, fs) = requests[0]
            val row = directReadFields(k, *fs.toTypedArray()) ?: return null
            return arrayOf(row)
        }

        val keys = Array(requests.size) { requests[it].first }
        val counts = IntArray(requests.size) { requests[it].second.size }
        val total = counts.sum()
        val fieldsFlat = Array(total) { "" }
        var off = 0
        for (r in requests) {
            for (f in r.second) fieldsFlat[off++] = f
        }
        return nativeSnapshotMHmget(keys, counts, fieldsFlat)
    }

    /**
     * Same as [directCommand] but returns the typed RESP value tree
     * ([RespValue]) instead of the raw string. Used by the type-safe
     * primitive wrappers to decode array / bulk / integer replies
     * without manual string parsing.
     *
     * Throws [DazzleException.CommandFailed] if the server replies with
     * a RESP error (`-ERR ...`).
     */
    fun commandTyped(vararg args: String): RespValue {
        val start = System.nanoTime()
        @Suppress("UNCHECKED_CAST")
        val raw = nativeDirectCommand(args as Array<String>)
        if (raw == null) {
            metrics.commandExecuted(
                command     = args.firstOrNull()?.uppercase() ?: "",
                argc        = args.size,
                latencyNanos = System.nanoTime() - start,
                success     = false,
            )
            throw DazzleException.TransportError(
                "directCommand(${args.joinToString(" ")}) returned null — server down?"
            )
        }
        val parsed = RespParser.parse(raw)
        metrics.commandExecuted(
            command     = args.firstOrNull()?.uppercase() ?: "",
            argc        = args.size,
            latencyNanos = System.nanoTime() - start,
            success     = parsed !is RespValue.Error,
        )
        (parsed as? RespValue.Error)?.let {
            throw DazzleException.CommandFailed(it.value)
        }
        return parsed
    }

    /**
     * Returns a high-level [Valkey] facade bound to this server. Use it
     * to access the type-safe primitive wrappers (`valkey.hash("key")`,
     * `valkey.stream("key")`, etc.) instead of constructing raw commands
     * with [directCommand].
     */
    fun client(): Dazzle = Dazzle(this)

    /**
     * Legacy single-string variant. Splits [command] by whitespace before
     * dispatch — any value containing a space is silently broken. Kept for
     * backward compat with pre-v1 consumers; new code should use the
     * variadic [directCommand] above.
     */
    @Deprecated(
        "String-splitting is unsafe for values with spaces. Use " +
            "directCommand(vararg args: String) instead.",
        ReplaceWith("directCommand(*command.split(\" \").toTypedArray())")
    )
    fun directCommand(command: String): String? {
        val parts = command.split(" ").filter { it.isNotEmpty() }.toTypedArray()
        return if (parts.isEmpty()) null else directCommand(*parts)
    }

    /**
     * Execute several commands in one round-trip through the in-process
     * pipe. Each inner list is one command.
     *
     * Returns one entry per input command. A `null` in position `i` means
     * command `i` failed or the pipe is closed.
     */
    fun directPipeline(commands: List<List<String>>): List<String?> {
        if (!isRunning() || commands.isEmpty()) return emptyList()
        val flat = mutableListOf<String>()
        val lengths = IntArray(commands.size)
        commands.forEachIndexed { i, cmd ->
            lengths[i] = cmd.size
            flat.addAll(cmd)
        }
        val replies = nativeDirectPipeline(flat.toTypedArray(), lengths)
        return replies.toList()
    }

    // ── Port probing ─────────────────────────────────────────────────────

    private fun pickFreePort(preferred: Int, range: IntRange, fallback: Boolean): Int {
        if (isPortFree(preferred)) return preferred
        if (!fallback) throw DazzleException.PortInUse(preferred)
        for (p in range) {
            if (p == preferred) continue
            if (isPortFree(p)) {
                logger.warn(TAG, "port $preferred in use, falling back to $p")
                return p
            }
        }
        throw DazzleException.NoFreePort(range)
    }

    private fun isPortFree(port: Int): Boolean = try {
        ServerSocket(port, /*backlog*/ 1, InetAddress.getByName("127.0.0.1")).use { true }
    } catch (_: IOException) {
        false
    }

    // ── Data-dir wiping ──────────────────────────────────────────────────

    private fun wipeDataDir(dataDir: File, targets: Set<WipeTarget>) {
        if (WipeTarget.AOF in targets) {
            val aof = File(dataDir, "appendonlydir")
            if (aof.exists()) {
                aof.deleteRecursively()
                logger.info(TAG, "wiped ${aof.absolutePath}")
            }
        }
        if (WipeTarget.RDB in targets) {
            dataDir.listFiles { f -> f.name.endsWith(".rdb") }
                ?.forEach {
                    it.delete()
                    logger.info(TAG, "wiped ${it.absolutePath}")
                }
        }
        if (WipeTarget.LOGS in targets) {
            val log = File(dataDir, "valkey.log")
            if (log.exists()) {
                log.delete()
                logger.info(TAG, "wiped ${log.absolutePath}")
            }
        }
    }

    // ── CLI arg construction ─────────────────────────────────────────────

    private fun buildCliArgs(
        configFile: File,
        dataDir: File,
        port: Int,
        modulePaths: List<String>,
        config: DazzleConfig,
    ): Array<String> {
        val args = mutableListOf<String>()
        args += "valkey-server"
        args += configFile.absolutePath
        args += "--dir"; args += dataDir.absolutePath
        args += "--port"; args += port.toString()
        args += "--bind"; args += config.bind
        // tcpEnabled = false → port 0 → no TCP listener. Valkey mainline
        // exits with "Configured to not listen anywhere" in that case;
        // patch 05_no_listener.patch removes the guard on Android / iOS
        // so the in-process fake-client path (dazzle_direct_init's
        // CLIENT_ID_CACHED_RESPONSE client) can serve directCommand /
        // directPipeline without needing any socket at all.
        args += "--maxmemory"; args += config.maxMemory
        args += "--daemonize"; args += "no"
        args += "--protected-mode"; args += if (config.protectedMode) "yes" else "no"
        args += "--logfile"; args += File(dataDir, "valkey.log").absolutePath
        args += "--loglevel"; args += "notice"
        args += "--ignore-warnings"; args += "ARM64-COW-BUG"

        // Thread-safety: disable observability side-effects that mutate
        // global lists / dicts / histograms from call().  The parallel-read
        // worker pool only guards the keyspace via a per-slot rwlock; the
        // commandlog (doubly-linked list), latency-events dict, and per-
        // command hdr_histogram are NOT protected and corrupt under
        // concurrent workers (SIGSEGV at adlist.c:203 'node->next->prev ==
        // node').  These observability counters aren't consumed on a mobile
        // deployment, so disable unconditionally — keeps the single-thread
        // path free from the cost, too.
        args += "--latency-monitor-threshold"; args += "0"
        args += "--latency-tracking";          args += "no"
        args += "--slowlog-log-slower-than";   args += "-1"
        args += "--slowlog-max-len";           args += "0"
        args += "--commandlog-request-larger-than"; args += "-1"
        args += "--commandlog-reply-larger-than";   args += "-1"

        // Persistence — explicit override of whatever valkey.conf says
        when (val p = config.persistence) {
            is DazzlePersistence.None -> {
                args += "--appendonly"; args += "no"
                args += "--save"; args += ""
            }
            is DazzlePersistence.Aof -> {
                args += "--appendonly"; args += "yes"
                args += "--appendfsync"; args += when (p.fsync) {
                    AppendFsync.ALWAYS   -> "always"
                    AppendFsync.EVERYSEC -> "everysec"
                    AppendFsync.NO       -> "no"
                }
                args += "--save"; args += ""
            }
            is DazzlePersistence.Rdb -> {
                args += "--appendonly"; args += "no"
                args += "--save"; args += p.savePolicy
            }
        }

        // Valkey native IO threads (ExecutionPolicy.ioThreads). Off-loads
        // socket read/write from the event loop. Only meaningful when TCP
        // is enabled — directCommand bypasses sockets entirely.
        if (config.execution.ioThreads > 0 && config.tcpEnabled) {
            args += "--io-threads"; args += config.execution.ioThreads.toString()
            args += "--io-threads-do-reads"; args += "yes"
        }

        // Modules
        for (mod in modulePaths) {
            args += "--loadmodule"; args += mod
        }

        // User extras (override anything above)
        for ((k, v) in config.extraArgs) {
            args += k; args += v
        }

        return args.toTypedArray()
    }

    private fun extractConfig(context: Context, dataDir: File): File {
        val configFile = File(dataDir, "valkey.conf")
        if (!configFile.exists()) {
            context.assets.open("valkey.conf").use { input ->
                FileOutputStream(configFile).use { output ->
                    input.copyTo(output)
                }
            }
        }
        return configFile
    }

    // ── JNI entry points ─────────────────────────────────────────────────

    private external fun nativeStart(cliArgs: Array<String>): Boolean
    private external fun nativeStop()
    private external fun nativeIsRunning(): Boolean
    private external fun nativeDirectCommand(args: Array<String>): String?
    private external fun nativeDirectRead(args: Array<String>): String?
    /** Phase 5: returns String?[] directly from the snapshot — no RESP encoding. */
    private external fun nativeDirectReadFields(key: String, fields: Array<String>): Array<String?>?
    private external fun nativeDirectReadField(key: String, field: String): String?
    private external fun nativeDirectHgetall(key: String): Array<String?>?
    private external fun nativeDirectSmembers(key: String): Array<String?>?
    private external fun nativeDirectZrangeByScore(key: String, min: Double, max: Double): Array<String?>?
    private external fun nativeDirectGetString(key: String): String?
    private external fun nativeDirectPipeline(flatArgs: Array<String>, lengths: IntArray): Array<String?>

    /** Set an env var before start() — `am start --es` doesn't reach getenv.
     * Used to flip DAZZLE_PARALLEL_READS=1 for Plan 02 benchmarks. */
    external fun nativeSetEnv(key: String, value: String): Boolean

    /** Plan 08: re-read ablation env flags (DAZZLE_DISABLE_SNAPSHOT,
     * DAZZLE_SNAPSHOT_BUCKETS) into transport-layer atomics. Sweep harnesses
     * that flip env vars across cells without killing the JVM should call
     * this after nativeSetEnv so the next operation observes the new
     * configuration. dazzle_direct_init also calls this internally on fresh
     * server starts, so single-config benchmarks do NOT need to call it. */
    external fun nativeSnapshotReloadConfig()

    /**
     * Phase 6a — multi-key typed snapshot HMGET. Single JNI crossing answers
     * N HMGETs under one rwlock. Returns an `Array<Array<String?>?>?`: the
     * outer null means the whole batch missed; each per-row null means the
     * caller should fall back to the pipe for that key only.
     */
    internal external fun nativeSnapshotMHmget(
        keys: Array<String>,
        fieldCounts: IntArray,
        fieldsFlat: Array<String>
    ): Array<Array<String?>?>?

    /**
     * Exposed to the `dev.dazzle.sdk` batch primitives (DazzlePrimitives.kt)
     * so they can reuse the existing N-in-1 write dispatcher.
     */
    internal fun directPipelineFlat(
        flatArgs: Array<String>,
        lengths: IntArray
    ): Array<String?> = nativeDirectPipeline(flatArgs, lengths)

    // ── Suspend variants (Plan 06) ────────────────────────────────────────
    // Non-breaking: original blocking funs stay untouched for single-threaded
    // callers. These suspend overloads move the JNI mutex wait off
    // Dispatchers.Default onto Dispatchers.IO, so K concurrent coroutines
    // can progress independently — same idiom as Swift's withCheckedContinuation.

    suspend fun directCommandSuspend(args: Array<String>): String? =
        withContext(Dispatchers.IO) { nativeDirectCommand(args) }

    suspend fun directReadSuspend(args: Array<String>): String? =
        withContext(Dispatchers.IO) { nativeDirectRead(args) }

    suspend fun directPipelineSuspend(
        flatArgs: Array<String>,
        lengths: IntArray
    ): Array<String?> =
        withContext(Dispatchers.IO) { nativeDirectPipeline(flatArgs, lengths) }

    internal suspend fun directPipelineFlatSuspend(
        flatArgs: Array<String>,
        lengths: IntArray
    ): Array<String?> =
        withContext(Dispatchers.IO) { nativeDirectPipeline(flatArgs, lengths) }
}
