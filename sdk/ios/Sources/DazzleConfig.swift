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

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// DazzleConfig  —  typed, explicit configuration for an embedded Valkey server
// instance on iOS. Mirrors dev.dazzle.sdk.DazzleConfig on the Android side
// field-for-field so the two platforms can share the same mental model and
// the same documentation.
// ─────────────────────────────────────────────────────────────────────────────

public struct DazzleConfig: Sendable {

    // ── Transport ─────────────────────────────────────────────────────────

    /// If false (DEFAULT), the server starts with `--port 0` — no TCP
    /// listener at all. `directCommand` / `directPipeline` still work
    /// because they go through the in-process pipe, not TCP.
    ///
    /// Dazzle is designed as an **in-process** embedded store (like
    /// SQLite): every primitive and every ChatAgent / ContextStore
    /// method takes the in-process path, never TCP. Exposing a
    /// loopback listener only matters when a debugger / benchmark /
    /// redis-cli needs to peek at the live server — flip this to
    /// `true` for those workflows and configure `port` accordingly.
    ///
    /// Prior to SDK beta.2 this defaulted to `true`, which caused
    /// every integrating app to reserve port 6379 even though the SDK
    /// itself never used it. The default is now `false` to match the
    /// embedded-store philosophy.
    public var tcpEnabled: Bool

    /// Preferred TCP port. If busy AND `allowPortFallback` is true, the
    /// library probes `portRange` for the first free port and logs a warning.
    public var port: Int

    /// Candidate ports to search when `port` is busy. Defaults to the
    /// "dazzle reserved" block, 6379..<6390.
    public var portRange: Range<Int>

    /// When true and `port` is in use, the library picks the first free port
    /// in `portRange`. When false, `start()` throws `DazzleError.portInUse`.
    public var allowPortFallback: Bool

    /// `--bind`. Defaults to loopback.
    public var bind: String

    /// `--protected-mode`. Defaults to false for the embedded in-process case.
    public var protectedMode: Bool

    // ── Memory ────────────────────────────────────────────────────────────

    /// `--maxmemory`. Accepts the standard Valkey suffixes (kb, mb, gb).
    public var maxMemory: String

    // ── Persistence ───────────────────────────────────────────────────────

    /// Mutually exclusive persistence choice. See `DazzlePersistence`.
    public var persistence: DazzlePersistence

    // ── Storage ───────────────────────────────────────────────────────────

    /// Directory where Valkey keeps its AOF / RDB / log files.
    /// Defaults to `<Documents>/valkey`.
    public var dataDir: URL?

    /// Artifacts to delete from `dataDir` BEFORE the server boots.
    public var wipeOnStart: WipeTarget

    // ── Modules ───────────────────────────────────────────────────────────

    /// Valkey modules to load at server startup. Only `.lua` is shipped in
    /// the current iOS build; requesting other modules throws
    /// `DazzleError.moduleUnavailable`.
    public var modules: Set<DazzleModule>

    // ── Misc ──────────────────────────────────────────────────────────────

    /// Logger injection point. Defaults to os_log under "dazzle".
    public var logger: any DazzleLogger

    /// Raw CLI args passed verbatim to `valkey-server`. Escape hatch for
    /// knobs not covered by typed fields. Later args override earlier ones.
    public var extraArgs: [(String, String)]

    /// Threading & concurrency policy. See `ExecutionPolicy` for the full
    /// list of knobs (parallel-read worker pool, Valkey IO threads, command
    /// timeout). Defaults to `.balanced` — auto-sized parallel reads, no
    /// IO threads — which is the right starting point for a single agent
    /// on a phone.
    public var execution: ExecutionPolicy

    public init(
        tcpEnabled: Bool = false,
        port: Int = DazzleConfig.defaultPort,
        portRange: Range<Int> = DazzleConfig.defaultPortRange,
        allowPortFallback: Bool = true,
        bind: String = "127.0.0.1",
        protectedMode: Bool = false,
        maxMemory: String = "64mb",
        persistence: DazzlePersistence = .aof(),
        dataDir: URL? = nil,
        wipeOnStart: WipeTarget = .none,
        modules: Set<DazzleModule> = [.lua],
        logger: any DazzleLogger = DefaultDazzleLogger(),
        extraArgs: [(String, String)] = [],
        execution: ExecutionPolicy = .balanced
    ) {
        precondition((0...65535).contains(port), "port must be in 0...65535")
        precondition(!portRange.isEmpty, "portRange must not be empty")
        self.tcpEnabled = tcpEnabled
        self.port = port
        self.portRange = portRange
        self.allowPortFallback = allowPortFallback
        self.bind = bind
        self.protectedMode = protectedMode
        self.maxMemory = maxMemory
        self.persistence = persistence
        self.dataDir = dataDir
        self.wipeOnStart = wipeOnStart
        self.modules = modules
        self.logger = logger
        self.extraArgs = extraArgs
        self.execution = execution
    }

    public static let defaultPort = 6379
    public static let defaultPortRange: Range<Int> = 6379..<6390
}

// ─────────────────────────────────────────────────────────────────────────────
// Persistence — sealed sum type via enum
// ─────────────────────────────────────────────────────────────────────────────

public enum DazzlePersistence: Sendable, Hashable {
    /// No persistence. In-memory only.
    case none

    /// Append-only log. Every write appended to `appendonly.aof`.
    case aof(fsync: AppendFsync = .everysec)

    /// Periodic binary snapshots.
    case rdb(savePolicy: String = DazzlePersistence.defaultSavePolicy)

    public static let defaultSavePolicy = "3600 1 300 100 60 10000"
}

public enum AppendFsync: Sendable, Hashable {
    case always
    case everysec
    case no
}

// ─────────────────────────────────────────────────────────────────────────────
// WipeTarget — composable cleanup flags
// ─────────────────────────────────────────────────────────────────────────────

public struct WipeTarget: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let aof  = WipeTarget(rawValue: 1 << 0)
    public static let rdb  = WipeTarget(rawValue: 1 << 1)
    public static let logs = WipeTarget(rawValue: 1 << 2)

    public static let none: WipeTarget = []
    public static let all:  WipeTarget = [.aof, .rdb, .logs]
}

// ─────────────────────────────────────────────────────────────────────────────
// Modules — mirror of dev.dazzle.sdk.DazzleModule
// ─────────────────────────────────────────────────────────────────────────────

public enum DazzleModule: Sendable, Hashable {
    /// Lua scripting (EVAL, EVALSHA, FUNCTION). Shipped in all iOS builds.
    case lua
    /// Vector similarity search (valkey-search). NOT shipped yet.
    case vectorSearch
    /// Time series (valkey-ts). NOT shipped yet.
    case timeSeries
    /// JSON document type (valkey-json). NOT shipped yet.
    case json
    /// Bloom filters / probabilistic structures (valkey-bloom). NOT shipped yet.
    case bloom
    /// Escape hatch: load an arbitrary module from a file you control.
    case custom(URL)

    internal var label: String {
        switch self {
        case .lua:          return "lua"
        case .vectorSearch: return "vector-search"
        case .timeSeries:   return "time-series"
        case .json:         return "json"
        case .bloom:        return "bloom"
        case .custom(let u): return u.lastPathComponent
        }
    }

    /// On iOS modules are statically linked into the main binary.
    /// --loadmodule @static:<name> uses dlopen(NULL) to find the OnLoad symbol.
    internal var isShippedOniOS: Bool {
        switch self {
        case .lua, .vectorSearch: return true
        default:                  return false
        }
    }

    /// Argv token passed to --loadmodule for statically linked modules.
    /// Returns nil for modules that don't need a --loadmodule flag (e.g. Lua).
    internal var staticModulePath: String? {
        switch self {
        case .vectorSearch: return "@static:vectorsearch"
        default:            return nil
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

public enum DazzleError: Error, LocalizedError, Sendable {
    case startFailed(String)
    case portInUse(Int)
    case noFreePort(Range<Int>)
    case moduleUnavailable(module: DazzleModule)
    case commandFailed(reply: String)
    case wrongType(key: String, expected: String, actual: String?)
    case outOfMemory(String)
    case transportError(String)
    case tcpDisabled(method: String)

    // ── Agent / LLM failures (Layer 2) ──────────────────────────────────
    case contextOverflow(tokensEstimated: Int, tokensAllowed: Int)
    case toolCallParseError(toolName: String, arguments: String)
    case modelLoadFailed(modelId: String, underlying: String?)
    case toolInvocationTimeout(toolName: String, timeoutMs: Int)
    case unknownTool(toolName: String, availableTools: [String])

    public var errorDescription: String? {
        switch self {
        case .startFailed(let msg):
            return "DazzleServer start failed: \(msg)"
        case .portInUse(let p):
            return "port \(p) is in use and allowPortFallback=false"
        case .noFreePort(let r):
            return "no free port in \(r) — pass a wider portRange or tcpEnabled=false"
        case .moduleUnavailable(let m):
            return "module '\(m.label)' is not shipped in this build of dazzle iOS. See ROADMAP.md."
        case .commandFailed(let r):
            return "command failed: \(r)"
        case .wrongType(let k, let e, let a):
            return "WRONGTYPE on key='\(k)' — expected \(e), got \(a ?? "unknown")"
        case .outOfMemory(let m):
            return m
        case .transportError(let m):
            return m
        case .tcpDisabled(let method):
            return "\(method) requires tcpEnabled=true — use directCommand instead"
        case .contextOverflow(let est, let allowed):
            return "LLM context overflow: prompt ≈\(est) tokens, model cap \(allowed). " +
                "Tighten ContextWindow or enable CompactionPolicy on the Agent."
        case .toolCallParseError(let name, let args):
            return "tool call for '\(name)' had unparseable arguments: \(args)"
        case .modelLoadFailed(let id, let underlying):
            return "failed to load LLM model '\(id)'" + (underlying.map { ": \($0)" } ?? "")
        case .toolInvocationTimeout(let name, let ms):
            return "tool '\(name)' did not complete within \(ms)ms"
        case .unknownTool(let name, let available):
            return "LLM requested tool '\(name)' but only these are registered: \(available)"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Logger — injection point
// ─────────────────────────────────────────────────────────────────────────────

public protocol DazzleLogger: Sendable {
    func debug(tag: String, _ message: String)
    func info(tag: String, _ message: String)
    func warn(tag: String, _ message: String)
    func error(tag: String, _ message: String, error: Error?)
}

public struct DefaultDazzleLogger: DazzleLogger {
    public init() {}
    public func debug(tag: String, _ message: String)           { print("[dazzle][\(tag)] DEBUG \(message)") }
    public func info(tag: String, _ message: String)            { print("[dazzle][\(tag)] INFO  \(message)") }
    public func warn(tag: String, _ message: String)            { print("[dazzle][\(tag)] WARN  \(message)") }
    public func error(tag: String, _ message: String, error: Error?) {
        if let e = error {
            print("[dazzle][\(tag)] ERROR \(message) — \(e)")
        } else {
            print("[dazzle][\(tag)] ERROR \(message)")
        }
    }
}
