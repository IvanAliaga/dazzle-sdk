// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Threading & concurrency configuration for the SDK.
///
/// Dazzle sits on top of Valkey's classic single-event-loop model and adds
/// four **extra** concurrency primitives that stock Valkey does not have:
///
///   1. Snapshot cache + rwlock  → lock-free `directRead` bypassing the pipe
///   2. Direct pipe commands     → in-process `directCommand` (no TCP)
///   3. Pipelined direct writes  → N writes in 1 FFI crossing
///   4. Parallel read worker pool → Plan 02, controlled by this policy
///
/// This struct mirrors the Android `ExecutionPolicy` class. The only
/// difference is that Swift consumers pick their dispatch context via
/// native `Task { }` / `@MainActor` / `TaskExecutor` (iOS 18+); the policy
/// here tunes the **native** worker pool + Valkey IO threads.
///
/// ## Recipe
///
/// ```swift
/// // Battery-sensitive — no parallel reads, no IO threads
/// try DazzleServer.shared.start(config: DazzleConfig(execution: .lean))
///
/// // Default balanced for a single agent on a phone
/// try DazzleServer.shared.start(config: DazzleConfig(execution: .balanced))
///
/// // Multi-agent / heavy concurrent searches
/// try DazzleServer.shared.start(config: DazzleConfig(execution: .parallel))
///
/// // Custom — pick and mix
/// try DazzleServer.shared.start(config: DazzleConfig(execution: ExecutionPolicy(
///     readWorkers:    2,
///     ioThreads:      1,
///     commandTimeout: .seconds(10)
/// )))
/// ```
public struct ExecutionPolicy: Sendable, Hashable {

    /// Size of the Dazzle parallel-read worker pool (Plan 02).
    ///
    /// - `0` → disabled (every read serializes on the event loop)
    /// - `-1` → auto-pick: `min(ncpu - 1, 4)`
    /// - `N > 0` → fixed size N
    public var readWorkers: Int

    /// Valkey native IO threads (`--io-threads N`). Off-loads socket
    /// read/write from the event loop. Only meaningful when `tcpEnabled`
    /// is true; in-process commands bypass sockets entirely.
    public var ioThreads: Int

    /// Upper bound for any single command issued through the SDK's
    /// async surface. Commands that take longer return a timeout error
    /// instead of blocking forever. Pass `.seconds(.max)` to disable.
    /// Does not apply to synchronous `directCommand` — that is bounded
    /// by the pipe semantics.
    public var commandTimeout: Duration

    public init(
        readWorkers: Int = 0,
        ioThreads: Int = 0,
        commandTimeout: Duration = .seconds(5)
    ) {
        precondition(readWorkers >= -1,
            "readWorkers must be >= -1 (-1 = auto, 0 = off, N = fixed); got \(readWorkers)")
        precondition(ioThreads >= 0,
            "ioThreads must be >= 0 (0 = off, N = enable N threads); got \(ioThreads)")
        self.readWorkers = readWorkers
        self.ioThreads = ioThreads
        self.commandTimeout = commandTimeout
    }

    /// Resolved worker-pool size after applying the auto rule.
    /// Internal — used by `DazzleServer.start` when wiring env vars.
    internal func effectiveReadWorkers(cpuCount: Int) -> Int {
        switch readWorkers {
        case -1:
            return min(max(1, cpuCount - 1), 4)
        default:
            return readWorkers
        }
    }

    /// Minimal-resource profile. All concurrency knobs off.
    public static let lean = ExecutionPolicy(readWorkers: 0, ioThreads: 0)

    /// Default for a single LLM agent on a phone. Parallel reads enabled
    /// with auto sizing; IO threads off (in-process pipe covers 99% of
    /// traffic on iOS).
    public static let balanced = ExecutionPolicy(readWorkers: -1, ioThreads: 0)

    /// Multi-agent / benchmark profile. Parallel reads + IO threads both
    /// enabled. Use when many concurrent semantic searches or TCP-served
    /// clients need to fan out across cores.
    public static let parallel = ExecutionPolicy(readWorkers: -1, ioThreads: 2)
}
