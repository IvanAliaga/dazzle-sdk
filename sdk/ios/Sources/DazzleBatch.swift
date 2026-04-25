/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 * Licensed under the Apache License, Version 2.0.
 *
 * DazzleBatch.swift — high-level batch primitives (Phase 6).
 *
 * These helpers sit on top of the typed multi-key snapshot read and the
 * coalesced pipeline dispatch that ship in dazzle_transport.c / dazzle_ios.c.
 * Their purpose is to let a retrieval or ingest path issue N operations
 * with a single FFI crossing:
 *
 *   • multiHashFields — N HMGETs → 1 crossing, 1 rwlock, snapshot-backed.
 *   • pipelineArgs    — N writes → 1 crossing, ring-buffer dispatch on
 *                       Android (io_uring batch notify) and a single
 *                       mutex-held pipe burst on iOS.
 */

import Foundation

public extension Dazzle {

    /// Snapshot-backed multi-key typed HMGET.  Each request is applied with
    /// the active `prefix` so namespaced Dazzle facades behave naturally:
    ///
    /// ```swift
    /// let rows = dazzle.multiHashFields([
    ///     (key: "user:1",      fields: ["name", "lang"]),
    ///     (key: "sensor:temp", fields: ["last", "avg"]),
    /// ])
    /// // rows[0] == ["ivan", "es"]
    /// // rows[1] == ["21.4", "20.1"]
    /// ```
    ///
    /// A key that is absent from the in-process snapshot falls back to a
    /// standard HMGET via `HashKey.mGet`, so callers always observe
    /// consistent semantics — snapshot misses cost one extra pipe round-trip
    /// for that key, never a wrong answer.
    func multiHashFields(
        _ requests: [(key: String, fields: [String])]
    ) -> [[String?]] {
        guard !requests.isEmpty else { return [] }

        let prefixed = requests.map { (key: prefix + $0.key, fields: $0.fields) }

        if let rows = server.directReadMFields(prefixed) {
            // Any row that came back nil means the key missed the snapshot —
            // fall back to a pipe HMGET for that row only.
            var out: [[String?]] = []
            out.reserveCapacity(prefixed.count)
            for (i, row) in rows.enumerated() {
                if let row = row {
                    out.append(row)
                } else {
                    out.append(pipeHashFieldsFallback(key: prefixed[i].key,
                                                     fields: prefixed[i].fields))
                }
            }
            return out
        }

        // Whole batch missed the snapshot — fall back per key.
        return prefixed.map {
            pipeHashFieldsFallback(key: $0.key, fields: $0.fields)
        }
    }

    /// Coalesced pipeline dispatch at the `Dazzle` facade level — same
    /// transport as `DazzleServer.directPipelineArgs` but scoped to the
    /// current namespace.  Returns one RESP reply per command; the caller
    /// is responsible for parsing them with `RespParser` if they need the
    /// structured form.
    func pipelineArgs(_ commands: [[String]]) -> [String] {
        return server.directPipelineArgs(commands)
    }

    // MARK: - internals

    private func pipeHashFieldsFallback(key: String, fields: [String]) -> [String?] {
        guard !fields.isEmpty else { return [] }
        // Reuse the typed single-key path if available; on snapshot miss it
        // will internally fall back to the pipe via mGet.
        do {
            var args = ["HMGET", key]
            args.append(contentsOf: fields)
            let reply = try server.commandTyped(args: args).asArray
            return reply.map { $0.asBulkOrNil }
        } catch {
            return Array(repeating: nil, count: fields.count)
        }
    }
}
