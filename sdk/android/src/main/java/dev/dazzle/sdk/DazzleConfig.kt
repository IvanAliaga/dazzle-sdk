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

import java.io.File

/**
 * Typed, explicit configuration for an embedded Valkey server instance.
 *
 * Every knob the server supports is declared here. Nothing is read from an
 * implicit `valkey.conf` in the assets and nothing is hardcoded in the
 * native layer — what you pass is what Valkey sees.
 *
 * See `README.md` for the full configuration cookbook; the
 * most common recipes are:
 *
 * ```kotlin
 * // Typical app cache — durable AOF, auto-pick port if 6379 is busy
 * DazzleServer.start(context, DazzleConfig())
 *
 * // Benchmark / experiment — no persistence, wipe any leftover artifacts,
 * // dedicated port
 * DazzleServer.start(context, DazzleConfig(
 *     port        = 6380,
 *     persistence = DazzlePersistence.None,
 *     wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB),
 * ))
 *
 * // In-process only — no TCP listener at all, immune to port conflicts.
 * // Only directCommand() / directPipeline() work; command() throws.
 * DazzleServer.start(context, DazzleConfig(tcpEnabled = false))
 * ```
 *
 * All values are immutable. To change a running server's configuration you
 * must [DazzleServer.stop] and start it again with a new [DazzleConfig].
 */
data class DazzleConfig(

    // ── Transport ─────────────────────────────────────────────────────────

    /** If false (DEFAULT), the server starts with `--port 0` — no TCP
     *  listener at all. `directCommand` / `directPipeline` still work
     *  because they go through the in-process JNI pipe, not through TCP.
     *
     *  Dazzle is designed as an **in-process** embedded store (like
     *  SQLite): every primitive and every ChatAgent / ContextStore
     *  method takes the JNI pipe path, never TCP. Exposing a loopback
     *  listener only matters when a debugger / benchmark / redis-cli
     *  needs to peek at the live server — flip this to `true` for
     *  those workflows and configure [port] accordingly.
     *
     *  Prior to SDK beta.2 this defaulted to `true`, which caused
     *  every integrating app to reserve port 6379 even though the SDK
     *  itself never used it. The default is now `false` to match the
     *  embedded-store philosophy. */
    val tcpEnabled: Boolean = false,

    /** Preferred TCP port. If this port is already in use AND
     *  [allowPortFallback] is true, the library probes [portRange] for the
     *  first free port and logs a warning. Ignored if [tcpEnabled] is false. */
    val port: Int = DEFAULT_PORT,

    /** Candidate ports to search when [port] is busy and [allowPortFallback]
     *  is true. Ignored if [tcpEnabled] is false. Defaults to the
     *  "Dazzle reserved" block, 6379..6389. */
    val portRange: IntRange = DEFAULT_PORT_RANGE,

    /** When true and [port] is in use, the library picks the first free
     *  port in [portRange]. When false, start() throws [DazzleException.PortInUse]. */
    val allowPortFallback: Boolean = true,

    /** `--bind` argument. Defaults to loopback-only for security. Set to
     *  "0.0.0.0" to expose to the LAN (requires [protectedMode] handling). */
    val bind: String = "127.0.0.1",

    /** `--protected-mode` toggle. Defaults to false because the embedded
     *  use case is trusted in-process. Set to true only if you expose the
     *  server over the network and want Valkey's built-in safety check. */
    val protectedMode: Boolean = false,

    // ── Memory ────────────────────────────────────────────────────────────

    /** `--maxmemory`. Accepts the standard Valkey suffixes (kb, mb, gb). */
    val maxMemory: String = "64mb",

    // ── Persistence ───────────────────────────────────────────────────────

    /** Persistence mode — mutually exclusive choice between None / Aof /
     *  Rdb. See [DazzlePersistence] for the shape of each variant. */
    val persistence: DazzlePersistence = DazzlePersistence.Aof(),

    // ── Storage ───────────────────────────────────────────────────────────

    /** Directory where Valkey keeps its AOF / RDB / log files. If null the
     *  library uses `<context.filesDir>/valkey`. */
    val dataDir: File? = null,

    /** Artifacts to delete from [dataDir] BEFORE the server boots. Used by
     *  tests / experiments to guarantee a cold start. See [WipeTarget] for
     *  the composable targets. */
    val wipeOnStart: Set<WipeTarget> = WipeTarget.NONE,

    // ── Direct read protocol ──────────────────────────────────────────────

    /**
     * Protocol used by [DazzleServer.directRead] and [HashKey.mGetDirect].
     *
     * | Mode | Description | Best for |
     * |------|-------------|----------|
     * | [DirectReadProtocol.TYPED] | Returns `String?[]` directly from the snapshot cache — no RESP encoding/decoding. Saves ~100 µs per call. **(default)** | New code, maximum performance |
     * | [DirectReadProtocol.RESP] | Returns a RESP-encoded string. Compatible with any Redis/Valkey client parser. | Code migrated from standard RESP3 clients, debugging, protocol inspection |
     *
     * Both modes read from the in-process snapshot cache (Phase 1 bypass) —
     * neither goes through the event-loop pipe for HMGET. The difference is
     * only in the return type and whether RESP serialisation happens.
     *
     * Developers coming from standard Valkey/Redis RESP3 clients can set
     * `RESP` to keep their existing RESP parsing logic intact; swap to
     * `TYPED` once ready to adopt the native String-array path.
     */
    val directReadProtocol: DirectReadProtocol = DirectReadProtocol.TYPED,

    // ── Modules ───────────────────────────────────────────────────────────

    /** Valkey modules to load at server startup. In Valkey 9+, the Lua
     *  scripting engine is built into the server core and no longer needs
     *  to be loaded as a module. Other modules (VectorSearch, TimeSeries,
     *  etc.) are not yet compiled for arm64. */
    val modules: Set<DazzleModule> = emptySet(),

    // ── Misc ──────────────────────────────────────────────────────────────

    /** Logger injection point. Defaults to android.util.Log. Pass your own
     *  implementation (Timber, SLF4J, Crashlytics, etc.) to capture library
     *  warnings and errors in your app's logging pipeline. */
    val logger: DazzleLogger = DazzleLogger.DEFAULT,

    /** Metrics injection point. Defaults to a no-op sink. Plug in a
     *  Prometheus / Firebase Performance / OpenTelemetry client to capture
     *  per-command latency and success/failure counters without patching
     *  the library source. See [DazzleMetrics]. */
    val metrics: DazzleMetrics = DazzleMetrics.DEFAULT,

    /** Raw CLI args passed verbatim to `valkey-server`. Escape hatch for
     *  knobs not covered by the typed fields above. Example:
     *  `listOf("--hz" to "20", "--tcp-backlog" to "256")`. Later args
     *  override earlier ones (including the ones the library generates
     *  from the typed fields). */
    val extraArgs: List<Pair<String, String>> = emptyList(),

    // ── Concurrency & execution ───────────────────────────────────────────

    /** Threading and parallelism policy for the SDK's suspend surface and
     *  for Dazzle's native worker pool. See [ExecutionPolicy] for the full
     *  list of knobs. Defaults to [ExecutionPolicy.balanced] — parallel
     *  reads auto-sized, IO threads off — which is the right starting
     *  point for a single agent on a phone. */
    val execution: ExecutionPolicy = ExecutionPolicy.balanced,
) {
    init {
        require(port in 0..65535) { "port must be in 0..65535, got $port" }
        require(!portRange.isEmpty()) { "portRange must not be empty" }
        require(portRange.first in 0..65535 && portRange.last in 0..65535) {
            "portRange must fit in 0..65535, got $portRange"
        }
    }

    companion object {
        /** Valkey's default TCP port, shared with Redis. */
        const val DEFAULT_PORT = 6379

        /** "Dazzle reserved" port block for port-fallback search. */
        val DEFAULT_PORT_RANGE = 6379..6389
    }
}
