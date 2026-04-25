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
import DazzleC

/// Embedded Valkey server for iOS.
/// Runs as an in-process database (like SQLite) on localhost TCP.
/// Uses a persistent connection to avoid ephemeral port exhaustion.
public final class DazzleServer {
    public static let shared = DazzleServer()

    private var _port: Int = 6379
    private let lock = NSLock()
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    private init() {}

    /// The TCP port the server is listening on.
    public var port: Int { _port }

    /// Whether the server is currently running.
    public var isRunning: Bool {
        dazzle_ios_is_running() != 0
    }

    private var currentConfig: DazzleConfig?
    private var currentDataDir: URL?

    /// Start the embedded Valkey server with a typed DazzleConfig.
    ///
    /// This is the primary entry point. The old `start(port:maxMemory:)`
    /// overload below delegates here with sensible defaults for
    /// backward compatibility.
    ///
    /// - Throws: `DazzleError.portInUse` if the preferred port is busy
    ///   and `config.allowPortFallback == false`; `DazzleError.noFreePort`
    ///   if no port in `config.portRange` is free; `DazzleError.moduleUnavailable`
    ///   if a requested module is not shipped; `DazzleError.startFailed` if
    ///   the native side returns failure.
    @discardableResult
    public func start(config: DazzleConfig) throws -> Bool {
        guard !isRunning else { return true }

        let logger = config.logger

        // Module sanity check — iOS currently ships only Lua via static linking.
        for mod in config.modules where !mod.isShippedOniOS {
            throw DazzleError.moduleUnavailable(module: mod)
        }

        // Resolve data dir
        let dataDir = config.dataDir ?? Self.defaultDataDirectory()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Wipe requested artifacts before booting
        if !config.wipeOnStart.isEmpty {
            Self.wipe(config.wipeOnStart, in: dataDir, logger: logger)
        }

        // Pick port (if TCP enabled)
        let portToUse: Int
        if config.tcpEnabled {
            portToUse = try Self.pickFreePort(
                preferred: config.port,
                range: config.portRange,
                fallback: config.allowPortFallback,
                logger: logger
            )
        } else {
            portToUse = 0
        }
        _port = portToUse

        // Apply ExecutionPolicy — parallel read worker pool via env vars.
        // Valkey reads them when dazzle_worker_pool.c initializes at boot,
        // so setenv MUST happen before dazzle_ios_start_argv. IO threads
        // flow through buildCliArgs below.
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let effectiveWorkers = config.execution.effectiveReadWorkers(cpuCount: cpuCount)
        if effectiveWorkers > 0 {
            setenv("DAZZLE_PARALLEL_READS", "1", 1)
            setenv("DAZZLE_WORKER_POOL_SIZE", String(effectiveWorkers), 1)
        } else {
            setenv("DAZZLE_PARALLEL_READS", "0", 1)
        }

        // Translate typed config → CLI argv
        let argv = Self.buildCliArgs(config: config, port: portToUse, dataDir: dataDir)

        logger.info(tag: "DazzleServer",
            "starting: port=\(portToUse) persistence=\(config.persistence) " +
            "modules=[\(config.modules.map { $0.label }.joined(separator: ","))] " +
            "execution=[readWorkers=\(effectiveWorkers) ioThreads=\(config.execution.ioThreads)] " +
            "dataDir=\(dataDir.path)")

        let ok = argv.withCStringArray { cArgs -> Int32 in
            dazzle_ios_start_argv(Int32(argv.count), cArgs)
        }

        if ok == 0 {
            throw DazzleError.startFailed(
                "native start returned failure — inspect " +
                dataDir.appendingPathComponent("valkey.log").path
            )
        }

        currentConfig = config
        currentDataDir = dataDir
        return true
    }

    /// Legacy start() kept for compatibility with pre-DazzleConfig callers.
    /// New code should use `start(config:)`.
    @available(*, deprecated, message: "Use start(config:) with DazzleConfig instead.")
    @discardableResult
    public func start(port: Int = 6379, maxMemory: String = "64mb") -> Bool {
        var cfg = DazzleConfig()
        cfg.port = port
        cfg.maxMemory = maxMemory
        return (try? start(config: cfg)) ?? false
    }

    /// Stop, wipe the requested artifacts, and restart with the current config.
    public func reset(wipe targets: WipeTarget = .all) throws {
        let cfg = currentConfig ?? DazzleConfig()
        let wasRunning = isRunning
        if wasRunning { stop() }

        let dir = currentDataDir ?? (cfg.dataDir ?? Self.defaultDataDirectory())
        Self.wipe(targets, in: dir, logger: cfg.logger)

        if wasRunning { try start(config: cfg) }
    }

    // ── Port probing ──────────────────────────────────────────────────────

    private static func pickFreePort(
        preferred: Int, range: Range<Int>, fallback: Bool, logger: any DazzleLogger
    ) throws -> Int {
        if isPortFree(preferred) { return preferred }
        if !fallback { throw DazzleError.portInUse(preferred) }
        for p in range where p != preferred {
            if isPortFree(p) {
                logger.warn(tag: "DazzleServer", "port \(preferred) in use, falling back to \(p)")
                return p
            }
        }
        throw DazzleError.noFreePort(range)
    }

    private static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var flag: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &flag, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(fd, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // ── Data-dir wiping ───────────────────────────────────────────────────

    private static func wipe(_ targets: WipeTarget, in dataDir: URL, logger: any DazzleLogger) {
        let fm = FileManager.default
        if targets.contains(.aof) {
            let aof = dataDir.appendingPathComponent("appendonlydir")
            if fm.fileExists(atPath: aof.path) {
                try? fm.removeItem(at: aof)
                logger.info(tag: "DazzleServer", "wiped \(aof.path)")
            }
        }
        if targets.contains(.rdb) {
            if let files = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "rdb" {
                    try? fm.removeItem(at: f)
                    logger.info(tag: "DazzleServer", "wiped \(f.path)")
                }
            }
        }
        if targets.contains(.logs) {
            let log = dataDir.appendingPathComponent("valkey.log")
            if fm.fileExists(atPath: log.path) {
                try? fm.removeItem(at: log)
                logger.info(tag: "DazzleServer", "wiped \(log.path)")
            }
        }
    }

    // ── CLI arg construction ──────────────────────────────────────────────

    private static func buildCliArgs(config: DazzleConfig, port: Int, dataDir: URL) -> [String] {
        var args = [String]()
        args += ["valkey-server"]
        args += ["--dir", dataDir.path]
        args += ["--port", String(port)]
        args += ["--bind", config.bind]
        args += ["--maxmemory", config.maxMemory]
        args += ["--daemonize", "no"]
        args += ["--protected-mode", config.protectedMode ? "yes" : "no"]
        args += ["--logfile", dataDir.appendingPathComponent("valkey.log").path]
        args += ["--loglevel", "notice"]

        switch config.persistence {
        case .none:
            args += ["--appendonly", "no", "--save", ""]
        case .aof(let fsync):
            args += ["--appendonly", "yes"]
            args += ["--appendfsync", {
                switch fsync {
                case .always:   return "always"
                case .everysec: return "everysec"
                case .no:       return "no"
                }
            }()]
            args += ["--save", ""]
        case .rdb(let policy):
            args += ["--appendonly", "no"]
            args += ["--save", policy]
        }

        // Valkey native IO threads (ExecutionPolicy.ioThreads). Off-loads
        // socket read/write from the event loop. Only meaningful when TCP
        // is enabled — directCommand bypasses sockets entirely.
        if config.execution.ioThreads > 0 && config.tcpEnabled {
            args += ["--io-threads", String(config.execution.ioThreads)]
            args += ["--io-threads-do-reads", "yes"]
        }

        // Static modules: pass --loadmodule @static:<name> so Valkey's
        // module loader calls dlopen(NULL) to find the OnLoad symbol that is
        // already compiled into this binary. Lua is integrated, not a module.
        for mod in config.modules {
            if let path = mod.staticModulePath {
                args += ["--loadmodule", path]
            }
        }

        // User extras last — they override everything above
        for (k, v) in config.extraArgs {
            args += [k, v]
        }

        return args
    }

    private static func defaultDataDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("valkey")
    }

    /// Build a type-safe VectorIndex handle for the given HNSW/FLAT index.
    /// Requires [DazzleModule.vectorSearch] in DazzleConfig.modules at start.
    public func vectorIndex(
        name: String,
        hashPrefix: String,
        vectorField: String = "embedding",
        dim: Int,
        algorithm: VectorIndex.Algorithm = .hnsw,
        metric: VectorIndex.Metric = .cosine
    ) -> VectorIndex {
        VectorIndex(
            server: self,
            name: name,
            hashPrefix: hashPrefix,
            vectorField: vectorField,
            dim: dim,
            algorithm: algorithm,
            metric: metric
        )
    }

    /// Gracefully stop the server. Waits until fully stopped.
    public func stop() {
        guard isRunning else { return }
        // Send shutdown through C helper (creates its own socket)
        dazzle_ios_stop(Int32(_port))
        // Close persistent connection after server processes SHUTDOWN
        disconnect()
        // Wait until server thread has fully exited
        let deadline = Date().addingTimeInterval(10.0)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Plan 08 ablation — re-read DAZZLE_DISABLE_SNAPSHOT and
    /// DAZZLE_SNAPSHOT_BUCKETS into transport-layer atomics.  Sweep
    /// harnesses that flip these env vars mid-run (without killing the
    /// host process) should call this after setenv so the next operation
    /// observes the new configuration.  dazzle_direct_init invokes it on
    /// every fresh server start, so single-config callers need not call.
    public func reloadSnapshotConfig() {
        valkey_snapshot_reload_config()
    }

    /// Wait until the server responds to PING (up to timeout seconds).
    /// Useful after start() to ensure the server is fully ready.
    @discardableResult
    public func waitForReady(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = command("PING"), r == "PONG" { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Send a raw RESP command and get the response.
    /// Uses a persistent TCP connection (auto-connects on first call).
    public func command(_ command: String) -> String? {
        guard isRunning else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let data = encodeCommand(command)

        for attempt in 0..<2 {
            if !ensureConnected() { return nil }
            guard let output = outputStream, let input = inputStream else { return nil }

            let written = data.withUnsafeBytes { ptr -> Int in
                output.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
            }
            if written != data.count {
                if attempt == 0 { reconnect(); continue }
                return nil
            }

            if let response = readResponse(from: input) {
                return response
            }
            print("[DazzleServer] command '\(command)' readResponse nil on attempt \(attempt)")
            if attempt == 0 { reconnect(); continue }
            return nil
        }
        return nil
    }

    /// Execute a Valkey command directly in-process (no TCP, no loopback).
    /// ~5x lower latency than command() for high-frequency operations.
    /// Returns a parsed response string, or nil on failure.
    public func directCommand(_ command: String) -> String? {
        guard isRunning else { return nil }
        let parts = command.split(separator: " ").map(String.init)
        return _directArgs(parts)
    }

    /// Execute multiple commands via the direct in-process path.
    /// Each command is dispatched sequentially; returns an array of responses.
    public func directPipeline(_ commands: [String]) -> [String] {
        guard isRunning, !commands.isEmpty else { return [] }
        return commands.compactMap { _directArgs($0.split(separator: " ").map(String.init)) }
    }

    /// Execute multiple pre-split commands via the direct in-process path.
    /// Unlike `directPipeline([String])`, args are NOT split by spaces AND
    /// replies come back as raw RESP bytes (not flattened), so callers can
    /// decode multi-bulk replies with `RespParser.parse`. The only caller
    /// today is `DazzlePipelineContextManager`, which needs the raw tree.
    public func directPipelineArgs(_ commands: [[String]]) -> [String] {
        guard isRunning, !commands.isEmpty else { return [] }

        // Phase 6b — one FFI crossing for the whole batch. Flatten commands
        // into lens[] + argv[] and let the C layer hold the event-loop mutex
        // once across all N writes.
        let n = commands.count
        var lens = [Int32](repeating: 0, count: n)
        var flat: [UnsafeMutablePointer<CChar>?] = []
        flat.reserveCapacity(commands.reduce(0) { $0 + $1.count })
        for (i, cmd) in commands.enumerated() {
            lens[i] = Int32(cmd.count)
            for s in cmd { flat.append(strdup(s)) }
        }
        defer { flat.forEach { if let p = $0 { free(p) } } }

        var argPtrs: [UnsafePointer<CChar>?] = flat.map { $0.map { UnsafePointer($0) } }
        var replies = [UnsafeMutablePointer<CChar>?](repeating: nil, count: n)

        let ok: Int32 = lens.withUnsafeMutableBufferPointer { lptr in
            argPtrs.withUnsafeMutableBufferPointer { aptr in
                replies.withUnsafeMutableBufferPointer { rptr in
                    valkey_pipeline_args(Int32(n),
                                         lptr.baseAddress,
                                         aptr.baseAddress,
                                         rptr.baseAddress)
                }
            }
        }
        guard ok != 0 else { return [] }

        var out: [String] = []
        out.reserveCapacity(n)
        for r in replies {
            if let p = r {
                out.append(String(cString: p))
                valkey_direct_free(p)
            }
        }
        return out
    }

    /// Execute a Valkey command directly in-process using pre-split argv.
    /// Unlike `directCommand(_ command: String)`, this does NOT split by
    /// spaces, so it handles values containing spaces (e.g. Lua scripts
    /// and JSON blob values). Safe to call from any thread.
    public func directArgs(_ parts: [String]) -> String? {
        return _directArgs(parts)
    }

    // ── Async variants (Plan 06) ──────────────────────────────────────────
    // Non-breaking: blocking funcs above are unchanged for single-threaded
    // callers. These async variants dispatch onto a background thread so K
    // concurrent Swift Tasks don't exhaust the cooperative thread pool —
    // same idiom as Kotlin's withContext(Dispatchers.IO).

    public func directArgsAsync(_ parts: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self._directArgs(parts))
            }
        }
    }

    public func directCommandAsync(_ command: String) async -> String? {
        let parts = command.split(separator: " ").map(String.init)
        return await directArgsAsync(parts)
    }

    public func directPipelineArgsAsync(_ commands: [[String]]) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.directPipelineArgs(commands))
            }
        }
    }

    private func _directArgs(_ parts: [String]) -> String? {
        guard !parts.isEmpty else { return nil }
        var cStrings = parts.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var constPtrs: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        let rawResult: UnsafeMutablePointer<CChar>? = constPtrs.withUnsafeMutableBufferPointer { buf in
            valkey_direct_command(Int32(parts.count), buf.baseAddress)
        }
        guard let rawResult else { return nil }
        defer { valkey_direct_free(rawResult) }
        let len = Int(strlen(rawResult))
        let data = Data(bytes: rawResult, count: len)
        return parseRESP(data).map { $0.0 }
    }

    /// Phase 5 typed direct-read — returns `[String?]` straight from the
    /// snapshot cache, skipping both the RESP serialise in C and the RESP
    /// parse in Swift. Nil element means the field is absent. Returns nil
    /// on cache miss so the caller can fall back to the pipe path.
    ///
    /// This is the iOS equivalent of
    /// `DazzleServer.directReadFields` on Android, and it is what
    /// `HashKey.mGetDirect` uses by default.
    internal func directReadFields(_ key: String, _ fields: [String]) -> [String?]? {
        let n = fields.count
        guard n > 0 else { return [] }

        // C expects const char ** for the field names and char **out for
        // the results. We strdup the field names so their lifetime survives
        // the closure, and allocate a local buffer of char* for `out`.
        var fieldBufs = fields.map { strdup($0) }
        defer { fieldBufs.forEach { free($0) } }
        var fieldPtrs: [UnsafePointer<CChar>?] = fieldBufs.map { $0.map { UnsafePointer($0) } }
        var outPtrs = [UnsafeMutablePointer<CChar>?](repeating: nil, count: n)

        let keyC = strdup(key)
        defer { free(keyC) }

        let hit: Int32 = fieldPtrs.withUnsafeMutableBufferPointer { fptr in
            outPtrs.withUnsafeMutableBufferPointer { optr in
                valkey_direct_read_fields(keyC, Int32(n),
                                          fptr.baseAddress,
                                          optr.baseAddress)
            }
        }
        guard hit != 0 else { return nil }   // snapshot miss → pipe fallback

        var result: [String?] = []
        result.reserveCapacity(n)
        for ptr in outPtrs {
            if let p = ptr {
                result.append(String(cString: p))
                free(p)   // each non-null slot was malloc'd by C
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// Phase 2 typed SMEMBERS — reads set members from the snapshot
    /// cache without encoding / parsing RESP. Returns `nil` on a
    /// snapshot miss or wrong-type entry so the caller falls back to
    /// the pipe path. Mirrors `DazzleServer.directSmembers` on Android.
    public func directSmembers(_ key: String) -> [String]? {
        let maxMembers = 64
        var out = [UnsafeMutablePointer<CChar>?](repeating: nil, count: maxMembers)
        let keyC = strdup(key)
        defer { free(keyC) }
        let written: Int32 = out.withUnsafeMutableBufferPointer { p in
            dazzle_snapshot_smembers_typed(keyC, p.baseAddress, Int32(maxMembers))
        }
        guard written >= 0 else { return nil }
        var result: [String] = []
        result.reserveCapacity(Int(written))
        for i in 0..<Int(written) {
            if let p = out[i] {
                result.append(String(cString: p))
                free(p)
            }
        }
        return result
    }

    /// Phase 2 typed ZRANGEBYSCORE — emits members whose score lies in
    /// `[min, max]` (both inclusive), ascending by score. `nil` on
    /// snapshot miss or wrong-type entry.
    public func directZrangeByScore(_ key: String, min: Double, max: Double) -> [String]? {
        let maxMembers = 64
        var out = [UnsafeMutablePointer<CChar>?](repeating: nil, count: maxMembers)
        let keyC = strdup(key)
        defer { free(keyC) }
        let written: Int32 = out.withUnsafeMutableBufferPointer { p in
            dazzle_snapshot_zrange_by_score_typed(keyC, min, max, p.baseAddress, Int32(maxMembers))
        }
        guard written >= 0 else { return nil }
        var result: [String] = []
        result.reserveCapacity(Int(written))
        for i in 0..<Int(written) {
            if let p = out[i] {
                result.append(String(cString: p))
                free(p)
            }
        }
        return result
    }

    /// Phase 2 typed GET for string keys. Returns `nil` on snapshot
    /// miss or wrong type. Caller falls back to pipe GET on nil.
    public func directGetString(_ key: String) -> String? {
        // Snapshot caps string values at SNAP_VAL_LEN; 4 KiB cap here
        // matches that plus headroom. `cap` captured outside the
        // withUnsafeMutableBufferPointer closure so Swift's exclusive-
        // access check doesn't see a second `buf` read through the
        // same inout binding.
        var buf = [CChar](repeating: 0, count: 4096)
        let cap = Int32(buf.count)
        let n: Int32 = buf.withUnsafeMutableBufferPointer { bp in
            let keyC = strdup(key)
            defer { free(keyC) }
            return dazzle_snapshot_get_string_typed(keyC, bp.baseAddress, cap)
        }
        guard n >= 0 else { return nil }
        return String(cString: buf)
    }

    /// Phase 7 typed HGETALL — reads every (field, value) pair stored for
    /// `key` in the snapshot cache without generating or parsing RESP.
    ///
    /// Returns `nil` on a snapshot miss so the caller falls back to the
    /// pipe path (the generic `HGETALL` via `directArgs`). On hit returns
    /// a dictionary built directly from the mallo'd C strings — no
    /// RESP encode in C, no Resp parser walk in Swift.
    ///
    /// Motivation: `DazzleContextStore.get` goes through `hash.getAll()`
    /// which today pays the full RESP round-trip. On records that are
    /// hot in the in-process snapshot that's pure waste; this bypass is
    /// the fast path `ContextStore.get` reaches for first.
    public func directHgetall(_ key: String) -> [String: String]? {
        // Upper bound matches SNAP_MAX_FIELDS in core/transport —
        // anything larger is by construction a miss on the snapshot.
        let maxPairs = 64
        var outFields = [UnsafeMutablePointer<CChar>?](repeating: nil, count: maxPairs)
        var outValues = [UnsafeMutablePointer<CChar>?](repeating: nil, count: maxPairs)

        let keyC = strdup(key)
        defer { free(keyC) }

        let written: Int32 = outFields.withUnsafeMutableBufferPointer { fPtr in
            outValues.withUnsafeMutableBufferPointer { vPtr in
                dazzle_snapshot_hgetall_typed(keyC,
                                              fPtr.baseAddress,
                                              vPtr.baseAddress,
                                              Int32(maxPairs))
            }
        }
        guard written >= 0 else { return nil }   // snapshot miss

        var result: [String: String] = [:]
        result.reserveCapacity(Int(written))
        for i in 0..<Int(written) {
            if let kp = outFields[i], let vp = outValues[i] {
                result[String(cString: kp)] = String(cString: vp)
            }
            if let kp = outFields[i] { free(kp) }
            if let vp = outValues[i] { free(vp) }
        }
        return result
    }

    /// Phase 6a multi-key typed snapshot HMGET. Returns one `[String?]` row
    /// per request; a nil row means that key missed the snapshot and the
    /// caller should fall back to the pipe for that key only. Returns the
    /// whole result as nil if the entire batch missed.
    internal func directReadMFields(
        _ requests: [(key: String, fields: [String])]
    ) -> [[String?]?]? {
        guard !requests.isEmpty else { return [] }
        if requests.count == 1 {
            let r = requests[0]
            guard let row = directReadFields(r.key, r.fields) else { return nil }
            return [row]
        }

        let nkeys = requests.count
        var keyBufs = requests.map { strdup($0.key) }
        defer { keyBufs.forEach { free($0) } }
        var keyPtrs: [UnsafePointer<CChar>?] = keyBufs.map { $0.map { UnsafePointer($0) } }

        var fieldCounts = [Int32](repeating: 0, count: nkeys)
        var fieldBufs: [UnsafeMutablePointer<CChar>?] = []
        for (i, r) in requests.enumerated() {
            fieldCounts[i] = Int32(r.fields.count)
            for f in r.fields { fieldBufs.append(strdup(f)) }
        }
        defer { fieldBufs.forEach { if let p = $0 { free(p) } } }
        var fieldPtrs: [UnsafePointer<CChar>?] = fieldBufs.map { $0.map { UnsafePointer($0) } }

        let total = fieldBufs.count
        if total == 0 { return requests.map { _ in [] } }
        var outPtrs = [UnsafeMutablePointer<CChar>?](repeating: nil, count: total)

        let hit: Int32 = keyPtrs.withUnsafeMutableBufferPointer { kptr in
            fieldCounts.withUnsafeMutableBufferPointer { cptr in
                fieldPtrs.withUnsafeMutableBufferPointer { fptr in
                    outPtrs.withUnsafeMutableBufferPointer { optr in
                        valkey_direct_read_mfields(Int32(nkeys),
                                                   kptr.baseAddress,
                                                   cptr.baseAddress,
                                                   fptr.baseAddress,
                                                   optr.baseAddress)
                    }
                }
            }
        }
        guard hit != 0 else { return nil }

        var rows: [[String?]?] = []
        rows.reserveCapacity(nkeys)
        var off = 0
        for i in 0..<nkeys {
            let nf = Int(fieldCounts[i])
            if nf == 0 { rows.append([]); continue }

            var rowAnyNonNil = false
            var row: [String?] = []
            row.reserveCapacity(nf)
            for j in 0..<nf {
                if let p = outPtrs[off + j] {
                    row.append(String(cString: p))
                    free(p)
                    rowAnyNonNil = true
                } else {
                    row.append(nil)
                }
            }
            // A row of all nils means the key missed the snapshot; the
            // transport leaves those slots NULL rather than zero-filling a
            // hit. Caller will fall back to the pipe for these.
            rows.append(rowAnyNonNil ? row : nil)
            off += nf
        }
        return rows
    }

    /// Phase 1 direct-read — answer HMGET from the snapshot cache without
    /// touching the event-loop pipe. Returns the raw RESP array string on
    /// cache hit, or nil on miss (caller should fall back to `directArgs`).
    internal func directReadArgs(_ parts: [String]) -> String? {
        guard !parts.isEmpty else { return nil }
        var cStrings = parts.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var constPtrs: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        let rawResult: UnsafeMutablePointer<CChar>? = constPtrs.withUnsafeMutableBufferPointer { buf in
            valkey_direct_read(Int32(parts.count), buf.baseAddress)
        }
        guard let rawResult else { return nil }  // cache miss
        defer { valkey_direct_free(rawResult) }
        return String(cString: rawResult)
    }

    /// Raw RESP-bytes path — same transport as `directArgs`, but returns the
    /// unmodified RESP bytes emitted by the C engine. The legacy `directArgs`
    /// runs `parseRESP` which flattens multi-bulk replies for the pre-typed
    /// string API; typed callers (`commandTyped`, `HashKey.mGet`, stream /
    /// sorted-set range queries) need the raw tree and use this path instead.
    ///
    /// Exposed as `public` because the React Native bridge uses it to hand
    /// the untouched RESP reply to the JS-side parser — the `directArgs`
    /// flatten would lose array structure and make `rangeByScore` /
    /// `HGETALL` round-trips unparseable on the JS side.
    public func directArgsRaw(_ parts: [String]) -> String? {
        guard !parts.isEmpty else { return nil }
        var cStrings = parts.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var constPtrs: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        let rawResult: UnsafeMutablePointer<CChar>? = constPtrs.withUnsafeMutableBufferPointer { buf in
            valkey_direct_command(Int32(parts.count), buf.baseAddress)
        }
        guard let rawResult else { return nil }
        defer { valkey_direct_free(rawResult) }
        return String(cString: rawResult)
    }

    /// Async variant of `directArgsRaw`. Matches the dispatch pattern used by
    /// `directArgsAsync` — offloads the C call to a background queue.
    public func directArgsRawAsync(_ parts: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.directArgsRaw(parts))
            }
        }
    }

    /// Send multiple commands in a single pipeline (no round-trip per command).
    /// Returns an array of responses, one per command.
    public func pipeline(_ commands: [String]) -> [String] {
        guard isRunning, !commands.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        var payload = Data()
        for cmd in commands {
            payload.append(encodeCommand(cmd))
        }

        for attempt in 0..<2 {
            if !ensureConnected() { return [] }
            guard let output = outputStream, let input = inputStream else { return [] }

            let written = payload.withUnsafeBytes { ptr -> Int in
                output.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: payload.count)
            }
            if written != payload.count {
                if attempt == 0 { reconnect(); continue }
                return []
            }

            var results = [String]()
            results.reserveCapacity(commands.count)
            var ok = true
            for _ in 0..<commands.count {
                if let r = readResponse(from: input) {
                    results.append(r)
                } else {
                    ok = false; break
                }
            }
            if ok { return results }
            if attempt == 0 { reconnect(); continue }
            return []
        }
        return []
    }

    // MARK: - Connection Management

    private func ensureConnected() -> Bool {
        if let i = inputStream, let o = outputStream,
           i.streamStatus == .open, o.streamStatus == .open {
            return true
        }
        return connect()
    }

    @discardableResult
    private func connect() -> Bool {
        disconnect()

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, "127.0.0.1" as CFString, UInt32(_port), &readStream, &writeStream)

        guard let input = readStream?.takeRetainedValue() as InputStream?,
              let output = writeStream?.takeRetainedValue() as OutputStream? else { return false }

        input.open()
        output.open()

        let deadline = Date().addingTimeInterval(2.0)
        while input.streamStatus == .opening, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }

        guard input.streamStatus == .open, output.streamStatus == .open else {
            input.close(); output.close()
            return false
        }

        inputStream = input
        outputStream = output
        return true
    }

    private func disconnect() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }

    private func reconnect() {
        disconnect()
        _ = connect()
    }

    // MARK: - RESP Encoding

    private func encodeCommand(_ command: String) -> Data {
        let parts = command.split(separator: " ").map(String.init)
        var resp = "*\(parts.count)\r\n"
        for part in parts {
            resp += "$\(part.utf8.count)\r\n\(part)\r\n"
        }
        return resp.data(using: .utf8)!
    }

    // MARK: - RESP Parsing

    private func readResponse(from input: InputStream) -> String? {
        var buffer = Data()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { chunk.deallocate() }

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            // Spin briefly waiting for bytes (loopback RTT ~0.1ms)
            var waited = 0
            while !input.hasBytesAvailable {
                waited += 1
                if waited > 100 { Thread.sleep(forTimeInterval: 0.0001) }
                if Date() >= deadline {
                    print("[DazzleServer] readResponse timeout, buf=\(buffer.count)")
                    return nil
                }
            }

            let n = input.read(chunk, maxLength: 65536)
            if n < 0 {
                print("[DazzleServer] readResponse read error n=\(n) status=\(input.streamStatus.rawValue) err=\(String(describing: input.streamError))")
                return nil
            }
            if n == 0 {
                // EOF on persistent connection — likely server closed it. Retry will reconnect.
                print("[DazzleServer] readResponse EOF n=0 buf=\(buffer.count) status=\(input.streamStatus.rawValue)")
                return nil
            }
            buffer.append(chunk, count: n)

            if let (parsed, _) = parseRESP(buffer) {
                return parsed
            }
        }
        print("[DazzleServer] readResponse deadline exceeded, buf=\(buffer.count)")
        return nil
    }

    private func parseRESP(_ data: Data) -> (String, Int)? {
        guard !data.isEmpty else { return nil }

        switch data[data.startIndex] {
        case UInt8(ascii: "+"):
            return parseLine(data, dropPrefix: true)

        case UInt8(ascii: "-"):
            guard let (line, n) = parseLine(data, dropPrefix: true) else { return nil }
            return ("ERROR: \(line)", n)

        case UInt8(ascii: ":"):
            return parseLine(data, dropPrefix: true)

        case UInt8(ascii: "$"):
            guard let (lenStr, headerLen) = parseLine(data, dropPrefix: true),
                  let len = Int(lenStr) else { return nil }
            if len == -1 { return ("nil", headerLen) }
            let needed = headerLen + len + 2
            guard data.count >= needed else { return nil }
            let s = data.index(data.startIndex, offsetBy: headerLen)
            let e = data.index(s, offsetBy: len)
            let str = String(data: data[s..<e], encoding: .utf8) ?? ""
            return (str, needed)

        case UInt8(ascii: "*"):
            guard let (countStr, headerLen) = parseLine(data, dropPrefix: true),
                  let count = Int(countStr) else { return nil }
            if count == -1 { return ("nil", headerLen) }
            var offset = headerLen
            var elements = [String]()
            for _ in 0..<count {
                guard offset < data.count else { return nil }
                let rest = Data(data[data.index(data.startIndex, offsetBy: offset)...])
                guard let (elem, consumed) = parseRESP(rest) else { return nil }
                elements.append(elem)
                offset += consumed
            }
            return (elements.joined(separator: "\n"), offset)

        default:
            return parseLine(data, dropPrefix: false)
        }
    }

    private func parseLine(_ data: Data, dropPrefix: Bool) -> (String, Int)? {
        guard let r = data.range(of: Data([0x0D, 0x0A])) else { return nil }
        let start = dropPrefix ? data.startIndex + 1 : data.startIndex
        guard let str = String(data: data[start..<r.lowerBound], encoding: .utf8) else { return nil }
        return (str, r.upperBound - data.startIndex)
    }

}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helper: pass a [String] to a C function expecting `const char **`.
// Each element is strdup'd into a temporary buffer; the buffer is freed after
// the closure returns.
// ─────────────────────────────────────────────────────────────────────────────

private extension Array where Element == String {
    func withCStringArray<Result>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Result) -> Result {
        let cStrings: [UnsafeMutablePointer<CChar>?] = self.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return ptrs.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }
}
