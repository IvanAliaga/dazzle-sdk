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
// DazzlePrimitives.swift
//
// Type-safe wrappers over the embedded Valkey server. One file contains
// all six primitives we ship in v1 (String / List / Hash / Set /
// SortedSet / Stream) plus the top-level `Valkey` facade, the RESP
// value tree, and the RESP parser.
//
// Mirrors the Kotlin counterpart in sdk/android/src/main/java/dev/dazzle/sdk/
// (1:1 with the DazzleServer primitive API) — every primitive takes the same arguments, returns
// the same shapes and runs on top of the same low-level directCommand
// path so both platforms feed Gemma byte-identical prompts.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - RespValue

public indirect enum RespValue: Sendable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    case bulk(String?)
    case array([RespValue]?)

    var asBulkOrNil: String? {
        switch self {
        case .bulk(let v):         return v
        case .simpleString(let v): return v
        case .integer(let v):      return String(v)
        default:                   return nil
        }
    }

    var asInt64OrNil: Int64? {
        switch self {
        case .integer(let v):      return v
        case .bulk(let v):         return v.flatMap { Int64($0) }
        case .simpleString(let v): return Int64(v)
        default:                   return nil
        }
    }

    var asArray: [RespValue] {
        if case .array(let items) = self { return items ?? [] }
        return []
    }

    var errorOrNil: String? {
        if case .error(let v) = self { return v }
        return nil
    }
}

// MARK: - RespParser

/// RESP-2 parser that operates on raw UTF-8 bytes, not grapheme clusters.
///
/// Swift collapses the CRLF pair into a single `Character` (it is a Unicode
/// canonical extended grapheme cluster), so a `String`-indexed parser will
/// silently skip or mis-align every `\r\n` separator and fail on multi-bulk
/// replies with `"unknown RESP type '\r\n'"`. Byte indexing avoids the
/// grapheme trap and also lets the parser handle arbitrary binary bulks.
internal enum RespParser {
    static func parse(_ raw: String) throws -> RespValue {
        let bytes = Array(raw.utf8)
        var pos = 0
        return try parseOne(bytes, pos: &pos)
    }

    private static func parseOne(_ b: [UInt8], pos: inout Int) throws -> RespValue {
        guard pos < b.count else {
            throw DazzleError.transportError("empty RESP reply")
        }
        let marker = b[pos]
        pos += 1
        switch marker {
        case 0x2B /* + */: return .simpleString(try readLine(b, pos: &pos))
        case 0x2D /* - */: return .error(try readLine(b, pos: &pos))
        case 0x3A /* : */:
            let line = try readLine(b, pos: &pos)
            guard let n = Int64(line) else {
                throw DazzleError.transportError("bad integer reply: \(line)")
            }
            return .integer(n)
        case 0x24 /* $ */:
            let header = try readLine(b, pos: &pos)
            guard let len = Int(header) else {
                throw DazzleError.transportError("bad bulk length header: \(header)")
            }
            if len == -1 { return .bulk(nil) }
            return .bulk(try readExact(b, pos: &pos, count: len))
        case 0x2A /* * */:
            let header = try readLine(b, pos: &pos)
            guard let n = Int(header) else {
                throw DazzleError.transportError("bad array header: \(header)")
            }
            if n == -1 { return .array(nil) }
            var items: [RespValue] = []
            items.reserveCapacity(n)
            for _ in 0..<n { items.append(try parseOne(b, pos: &pos)) }
            return .array(items)
        default:
            throw DazzleError.transportError(
                "unknown RESP type 0x\(String(marker, radix: 16)) at offset \(pos - 1)"
            )
        }
    }

    private static func readLine(_ b: [UInt8], pos: inout Int) throws -> String {
        var i = pos
        while i + 1 < b.count {
            if b[i] == 0x0D /* \r */ && b[i + 1] == 0x0A /* \n */ {
                let line = String(decoding: b[pos..<i], as: UTF8.self)
                pos = i + 2
                return line
            }
            i += 1
        }
        throw DazzleError.transportError("malformed RESP: no CRLF")
    }

    private static func readExact(_ b: [UInt8], pos: inout Int, count: Int) throws -> String {
        guard pos + count <= b.count else {
            throw DazzleError.transportError("malformed RESP: not enough bytes")
        }
        let payload = String(decoding: b[pos..<(pos + count)], as: UTF8.self)
        pos += count
        // Skip trailing CRLF.
        if pos + 1 < b.count && b[pos] == 0x0D && b[pos + 1] == 0x0A {
            pos += 2
        } else if pos < b.count && b[pos] == 0x0A {
            pos += 1
        }
        return payload
    }
}

// MARK: - DazzleServer.commandTyped extension

public extension DazzleServer {
    /// Run a command via the in-process direct path and parse the reply
    /// into a typed [RespValue] tree. Throws `DazzleError.commandFailed`
    /// if the server replies with a RESP error.
    func commandTyped(_ args: String...) throws -> RespValue {
        return try commandTyped(args: args)
    }

    func commandTyped(args: [String]) throws -> RespValue {
        guard !args.isEmpty else {
            throw DazzleError.transportError("empty command")
        }
        // IMPORTANT: use the RAW RESP path here, not _lowLevelDirectCommand.
        // The legacy path runs `parseRESP` which flattens multi-bulk replies
        // into a "value1\nvalue2\n..." string; RespParser.parse then fails
        // on the first byte (which is data, not a RESP marker). The raw path
        // returns the bytes straight from the C engine so RespParser can
        // build a proper typed tree including nested arrays.
        guard let raw = _lowLevelDirectCommandRaw(args) else {
            throw DazzleError.transportError(
                "directCommand(\(args.joined(separator: " "))) returned nil — server down?"
            )
        }
        let parsed = try RespParser.parse(raw)
        if case .error(let msg) = parsed {
            throw DazzleError.commandFailed(reply: msg)
        }
        return parsed
    }

    /// Entry point used by the primitive wrappers. Wraps the existing
    /// `directCommand(String)` path to send a single variadic command.
    /// On iOS the pre-refactor API stays string-based at the DazzleServer
    /// layer; the typed primitives build the argv array and join it.
    internal func _lowLevelDirectCommand(_ args: [String]) -> String? {
        // Use directArgs which bypasses space-splitting, correctly
        // handling values that contain spaces (e.g. Lua scripts).
        return self.directArgs(args)
    }

    /// Raw RESP-bytes path. Unlike _lowLevelDirectCommand this does NOT
    /// flatten multi-bulk replies — it returns the exact bytes emitted by
    /// the C engine so RespParser can decode arbitrary RESP trees. Used by
    /// `commandTyped` and by the typed primitive APIs (`HashKey.mGet`,
    /// `StreamKey.revRange`, `SortedSetKey.rangeByScore`, etc.).
    internal func _lowLevelDirectCommandRaw(_ args: [String]) -> String? {
        return self.directArgsRaw(args)
    }

    /// Obtain a high-level [Valkey] facade over this server.
    func client() -> Dazzle { Dazzle(server: self) }
}

// MARK: - Valkey facade

public final class Dazzle: Sendable {
    internal let server: DazzleServer
    // `internal` (not `private`) so the extension in DazzleBatch.swift — a
    // different file in the same module — can compose a prefixed key.
    internal let prefix: String

    internal init(server: DazzleServer, prefix: String = "") {
        self.server = server
        self.prefix = prefix
    }

    // ── Primitive factories ───────────────────────────────────────────────

    public func string(_ key: String)       -> StringKey       { StringKey(key: prefix + key, server: server) }
    public func list(_ key: String)         -> ListKey         { ListKey(key: prefix + key, server: server) }
    public func hash(_ key: String)         -> HashKey         { HashKey(key: prefix + key, server: server) }
    public func set(_ key: String)          -> SetKey          { SetKey(key: prefix + key, server: server) }
    public func sortedSet(_ key: String)    -> SortedSetKey    { SortedSetKey(key: prefix + key, server: server) }
    public func stream(_ key: String)       -> StreamKey       { StreamKey(key: prefix + key, server: server) }
    public func bitmap(_ key: String)       -> BitmapKey       { BitmapKey(key: prefix + key, server: server) }
    public func geo(_ key: String)          -> GeoKey          { GeoKey(key: prefix + key, server: server) }
    public func hyperLogLog(_ key: String)  -> HyperLogLogKey  { HyperLogLogKey(key: prefix + key, server: server) }

    public func namespace(_ name: String) -> Dazzle {
        Dazzle(server: server, prefix: "\(prefix)\(name):")
    }

    // ── Key meta ops ──────────────────────────────────────────────────────

    @discardableResult
    public func exists(_ keys: String...) throws -> Int64 {
        guard !keys.isEmpty else { return 0 }
        var args = ["EXISTS"]
        args.append(contentsOf: keys.map { prefix + $0 })
        return try server.commandTyped(args: args).asInt64OrNil ?? 0
    }

    @discardableResult
    public func delete(_ keys: String...) throws -> Int64 {
        guard !keys.isEmpty else { return 0 }
        var args = ["DEL"]
        args.append(contentsOf: keys.map { prefix + $0 })
        return try server.commandTyped(args: args).asInt64OrNil ?? 0
    }

    public func type(_ key: String) throws -> String {
        (try server.commandTyped("TYPE", prefix + key)).asBulkOrNil ?? "none"
    }

    // ── TTL family ────────────────────────────────────────────────────────

    @discardableResult
    public func expire(_ key: String, seconds: Int64) throws -> Bool {
        (try server.commandTyped("EXPIRE", prefix + key, String(seconds))).asInt64OrNil == 1
    }
    @discardableResult
    public func pExpire(_ key: String, millis: Int64) throws -> Bool {
        (try server.commandTyped("PEXPIRE", prefix + key, String(millis))).asInt64OrNil == 1
    }
    @discardableResult
    public func expireAt(_ key: String, unixSeconds: Int64) throws -> Bool {
        (try server.commandTyped("EXPIREAT", prefix + key, String(unixSeconds))).asInt64OrNil == 1
    }
    @discardableResult
    public func persist(_ key: String) throws -> Bool {
        (try server.commandTyped("PERSIST", prefix + key)).asInt64OrNil == 1
    }
    public func ttl(_ key: String) throws -> Int64 {
        (try server.commandTyped("TTL", prefix + key)).asInt64OrNil ?? -2
    }
    public func pTtl(_ key: String) throws -> Int64 {
        (try server.commandTyped("PTTL", prefix + key)).asInt64OrNil ?? -2
    }

    // ── Server-level meta ops ─────────────────────────────────────────────

    public func dbSize() throws -> Int64 {
        (try server.commandTyped("DBSIZE")).asInt64OrNil ?? 0
    }
    @discardableResult
    public func flushDb() throws -> Bool {
        if case .simpleString(let v) = try server.commandTyped("FLUSHDB") { return v == "OK" }
        return false
    }
    @discardableResult
    public func flushAll() throws -> Bool {
        if case .simpleString(let v) = try server.commandTyped("FLUSHALL") { return v == "OK" }
        return false
    }
    public func ping() throws -> Bool {
        if case .simpleString(let v) = try server.commandTyped("PING") { return v == "PONG" }
        return false
    }

    // MARK: - Transactions

    /// WATCH the given keys for optimistic locking.
    public func watch(_ keys: String...) throws {
        guard !keys.isEmpty else { return }
        var args = ["WATCH"]
        args.append(contentsOf: keys.map { prefix + $0 })
        _ = try server.commandTyped(args: args)
    }

    /// UNWATCH — cancel any outstanding WATCH.
    public func unwatch() throws {
        _ = try server.commandTyped("UNWATCH")
    }

    // MARK: - Pub/Sub

    /// PUBLISH message to channel. Returns the number of subscribers that received it.
    @discardableResult
    public func publish(_ channel: String, _ message: String) throws -> Int64 {
        (try server.commandTyped("PUBLISH", prefix + channel, message)).asInt64OrNil ?? 0
    }

    // MARK: - Scripting

    /// Obtain a Lua script handle bound to this server.
    public func script(_ source: String) -> LuaScript { LuaScript(source: source, server: server) }

    // MARK: - Scan iteration

    /// Cursor-based iteration over the keyspace. Returns batches of
    /// matching keys as an AnyIterator — one network round-trip per
    /// batch. Safe for huge keyspaces.
    public func scan(match: String? = nil, count: Int64? = nil) -> AnyIterator<[String]> {
        var cursor = "0"
        var done = false
        let prefix = self.prefix
        let server = self.server
        return AnyIterator {
            while !done {
                var args = ["SCAN", cursor]
                if let m = match { args += ["MATCH", prefix + m] }
                if let c = count { args += ["COUNT", String(c)] }
                guard let reply = try? server.commandTyped(args: args) else { done = true; return nil }
                let arr = reply.asArray
                cursor = arr.first?.asBulkOrNil ?? "0"
                let batch = arr.dropFirst().first?.asArray.compactMap { $0.asBulkOrNil } ?? []
                if cursor == "0" { done = true }
                if !batch.isEmpty { return batch }
            }
            return nil
        }
    }
}

// MARK: - LuaScript

public final class LuaScript: @unchecked Sendable {
    public let source: String
    internal let server: DazzleServer
    private var sha1: String?
    private let lock = NSLock()

    internal init(source: String, server: DazzleServer) {
        self.source = source
        self.server = server
    }

    /// EVAL source numkeys key... arg... — runs the script. On the first
    /// call the server caches the script by SHA1; subsequent calls use
    /// EVALSHA under the hood for lower bandwidth.
    @discardableResult
    public func eval(keys: [String] = [], args: [String] = []) throws -> RespValue {
        lock.lock(); let cachedSha = sha1; lock.unlock()
        if let sha = cachedSha {
            do {
                return try evalShaInternal(sha: sha, keys: keys, args: args)
            } catch DazzleError.commandFailed(let reply) where reply.hasPrefix("NOSCRIPT") {
                // server cache evicted — fall through to full EVAL
            }
        }
        var cmd = ["EVAL", source, String(keys.count)]
        cmd.append(contentsOf: keys)
        cmd.append(contentsOf: args)
        let reply = try server.commandTyped(args: cmd)
        if cachedSha == nil { _ = try? load() }
        return reply
    }

    @discardableResult
    public func evalSha(keys: [String] = [], args: [String] = []) throws -> RespValue {
        let sha: String
        lock.lock()
        if let s = sha1 {
            sha = s
            lock.unlock()
        } else {
            lock.unlock()
            sha = try load()
        }
        return try evalShaInternal(sha: sha, keys: keys, args: args)
    }

    private func evalShaInternal(sha: String, keys: [String], args: [String]) throws -> RespValue {
        var cmd = ["EVALSHA", sha, String(keys.count)]
        cmd.append(contentsOf: keys)
        cmd.append(contentsOf: args)
        return try server.commandTyped(args: cmd)
    }

    /// SCRIPT LOAD — upload without running, caches the SHA.
    @discardableResult
    public func load() throws -> String {
        guard let sha = (try server.commandTyped("SCRIPT", "LOAD", source)).asBulkOrNil else {
            throw DazzleError.transportError("SCRIPT LOAD returned unexpected reply")
        }
        lock.lock(); sha1 = sha; lock.unlock()
        return sha
    }
}

// MARK: - HashKey

public struct HashKey: Sendable {
    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func set(_ field: String, _ value: String) throws -> Bool {
        (try server.commandTyped("HSET", key, field, value)).asInt64OrNil == 1
    }

    @discardableResult
    public func setAll(_ pairs: [String: String]) throws -> Int64 {
        guard !pairs.isEmpty else { return 0 }
        var args = ["HSET", key]
        for (k, v) in pairs { args.append(k); args.append(v) }
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    public func get(_ field: String) throws -> String? {
        (try server.commandTyped("HGET", key, field)).asBulkOrNil
    }

    public func getAll() throws -> [String: String] {
        let items = (try server.commandTyped("HGETALL", key)).asArray
        var out: [String: String] = [:]
        var i = 0
        while i < items.count - 1 {
            let k = items[i].asBulkOrNil ?? ""
            let v = items[i + 1].asBulkOrNil ?? ""
            out[k] = v
            i += 2
        }
        return out
    }

    /// Snapshot-typed HGETALL — reads every (field, value) pair for this
    /// hash without encoding / parsing RESP. Drops ~50-80 µs per call vs
    /// `getAll` on records already hot in the snapshot cache.
    ///
    /// Falls back to `getAll` on a snapshot miss, so the fast path is a
    /// pure win: consumers call this unconditionally and the pipe path
    /// is only paid on records that haven't been written yet.
    ///
    /// Used by `DazzleContextStore.get` to recover the pre-refactor lead
    /// over ObjectBox / SQLite-AI that regressed when ContextStore was
    /// switched to the generic RESP path.
    public func getAllDirect() throws -> [String: String] {
        if let hit = server.directHgetall(key) { return hit }
        return try getAll()
    }

    @discardableResult
    public func delete(_ fields: String...) throws -> Int64 {
        guard !fields.isEmpty else { return 0 }
        var args = ["HDEL", key]
        args.append(contentsOf: fields)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    public func exists(_ field: String) throws -> Bool {
        (try server.commandTyped("HEXISTS", key, field)).asInt64OrNil == 1
    }

    public func length() throws -> Int64 {
        (try server.commandTyped("HLEN", key)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func incrBy(_ field: String, _ delta: Int64) throws -> Int64 {
        (try server.commandTyped("HINCRBY", key, field, String(delta))).asInt64OrNil ?? 0
    }

    @discardableResult
    public func incrByFloat(_ field: String, _ delta: Double) throws -> Double {
        Double((try server.commandTyped("HINCRBYFLOAT", key, field, String(delta))).asBulkOrNil ?? "") ?? 0
    }

    public func mGet(_ fields: String...) throws -> [String?] {
        guard !fields.isEmpty else { return [] }
        var args = ["HMGET", key]
        args.append(contentsOf: fields)
        return (try server.commandTyped(args: args)).asArray.map { $0.asBulkOrNil }
    }

    /// Phase 1 + 5 direct-read — HMGET answered from the snapshot cache
    /// (zero pipe, zero event loop). Uses the typed `directReadFields`
    /// bridge (Phase 5: skips RESP envelope + parse, ~30–80 µs saved)
    /// and falls back to `mGet` on cache miss so the caller never sees a
    /// stale-cache inconsistency.
    public func mGetDirect(_ fields: String...) throws -> [String?] {
        guard !fields.isEmpty else { return [] }
        if let typed = server.directReadFields(key, Array(fields)) {
            return typed
        }
        // Snapshot miss — pipe fallback, preserves the same semantics.
        var args = ["HMGET", key]
        args.append(contentsOf: fields)
        return try server.commandTyped(args: args).asArray.map { $0.asBulkOrNil }
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }

    /// Snapshot-cache direct field read — ~6× faster than `get` for
    /// supported hash fields. Falls back to RESP `HGET` on miss so
    /// semantics stay consistent.
    public func getDirect(_ field: String) throws -> String? {
        if let typed = server.directReadFields(key, [field])?.first { return typed }
        return try get(field)
    }

    /// HKEYS key — all field names.
    public func keys() throws -> [String] {
        (try server.commandTyped("HKEYS", key)).asArray.compactMap { $0.asBulkOrNil }
    }

    /// HVALS key — all values (no field names).
    public func values() throws -> [String] {
        (try server.commandTyped("HVALS", key)).asArray.compactMap { $0.asBulkOrNil }
    }

    /// HSCAN iterator — cursor-paginated field/value map. `match` is
    /// a standard Valkey pattern (`*`, `?`, `[abc]`) against the field.
    public func scan(match: String? = nil, count: Int64? = nil) -> AnyIterator<[String: String]> {
        var cursor = "0"
        var done = false
        return AnyIterator { [self] in
            if done { return nil }
            var args = ["HSCAN", self.key, cursor]
            if let m = match { args += ["MATCH", m] }
            if let c = count { args += ["COUNT", String(c)] }
            let reply: RespValue
            do { reply = try self.server.commandTyped(args: args) } catch { done = true; return nil }
            let arr = reply.asArray
            cursor = arr.first?.asBulkOrNil ?? "0"
            let pairs = (arr.count > 1 ? arr[1].asArray : [])
            var out: [String: String] = [:]
            var i = 0
            while i + 1 < pairs.count {
                let k = pairs[i].asBulkOrNil ?? ""
                let v = pairs[i + 1].asBulkOrNil ?? ""
                out[k] = v
                i += 2
            }
            if cursor == "0" { done = true }
            return out.isEmpty && done ? nil : out
        }
    }

    // MARK: - Hash Field Expiration (Valkey 8)
    //
    // Each field in a hash can carry its own TTL, independent of the
    // key-level TTL. The signature Valkey-8 capability with no SQLite
    // equivalent. Return codes per field:
    //   1 → TTL applied
    //   0 → field exists but NX/XX/GT/LT blocked the change
    //  -2 → field does not exist

    @discardableResult
    public func expireField(_ field: String, seconds: Int64) throws -> Int {
        let r = try server.commandTyped(args: [
            "HEXPIRE", key, String(seconds), "FIELDS", "1", field
        ]).asArray
        return Int(r.first?.asInt64OrNil ?? -2)
    }

    /// HEXPIRE in one call for several fields. Returns one status code per
    /// field, in the same order as the input. See [expireField] for codes.
    public func expireFields(seconds: Int64, _ fields: String...) throws -> [Int] {
        guard !fields.isEmpty else { return [] }
        var args = ["HEXPIRE", key, String(seconds), "FIELDS", String(fields.count)]
        args.append(contentsOf: fields)
        return (try server.commandTyped(args: args)).asArray.map { Int($0.asInt64OrNil ?? -2) }
    }

    @discardableResult
    public func pExpireField(_ field: String, millis: Int64) throws -> Int {
        let r = try server.commandTyped(args: [
            "HPEXPIRE", key, String(millis), "FIELDS", "1", field
        ]).asArray
        return Int(r.first?.asInt64OrNil ?? -2)
    }

    public func pExpireFields(millis: Int64, _ fields: String...) throws -> [Int] {
        guard !fields.isEmpty else { return [] }
        var args = ["HPEXPIRE", key, String(millis), "FIELDS", String(fields.count)]
        args.append(contentsOf: fields)
        return (try server.commandTyped(args: args)).asArray.map { Int($0.asInt64OrNil ?? -2) }
    }

    @discardableResult
    public func expireFieldAt(_ field: String, unixSeconds: Int64) throws -> Int {
        let r = try server.commandTyped(args: [
            "HEXPIREAT", key, String(unixSeconds), "FIELDS", "1", field
        ]).asArray
        return Int(r.first?.asInt64OrNil ?? -2)
    }

    public func ttlField(_ field: String) throws -> Int64 {
        let r = try server.commandTyped(args: [
            "HTTL", key, "FIELDS", "1", field
        ]).asArray
        return r.first?.asInt64OrNil ?? -2
    }

    /// Like [ttlField] but for multiple fields in one call. Returns one
    /// TTL per input field, in the same order. `-2` = field missing,
    /// `-1` = no TTL, `N` = seconds remaining.
    public func ttlFields(_ fields: String...) throws -> [Int64] {
        guard !fields.isEmpty else { return [] }
        var args = ["HTTL", key, "FIELDS", String(fields.count)]
        args.append(contentsOf: fields)
        return (try server.commandTyped(args: args)).asArray.map { $0.asInt64OrNil ?? -2 }
    }

    public func pTtlField(_ field: String) throws -> Int64 {
        let r = try server.commandTyped(args: [
            "HPTTL", key, "FIELDS", "1", field
        ]).asArray
        return r.first?.asInt64OrNil ?? -2
    }

    public func pTtlFields(_ fields: String...) throws -> [Int64] {
        guard !fields.isEmpty else { return [] }
        var args = ["HPTTL", key, "FIELDS", String(fields.count)]
        args.append(contentsOf: fields)
        return (try server.commandTyped(args: args)).asArray.map { $0.asInt64OrNil ?? -2 }
    }

    @discardableResult
    public func persistField(_ field: String) throws -> Bool {
        let r = try server.commandTyped(args: [
            "HPERSIST", key, "FIELDS", "1", field
        ]).asArray
        return (r.first?.asInt64OrNil ?? -2) == 1
    }
}

// MARK: - BitmapKey

public struct BitmapKey: Sendable {
    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func setBit(_ offset: Int64, _ bit: Bool) throws -> Bool {
        let prev = (try server.commandTyped("SETBIT", key, String(offset), bit ? "1" : "0")).asInt64OrNil ?? 0
        return prev == 1
    }

    public func getBit(_ offset: Int64) throws -> Bool {
        (try server.commandTyped("GETBIT", key, String(offset))).asInt64OrNil == 1
    }

    public func count(start: Int64? = nil, end: Int64? = nil) throws -> Int64 {
        var args = ["BITCOUNT", key]
        if let s = start, let e = end { args += [String(s), String(e)] }
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    public func firstPosition(_ bit: Bool) throws -> Int64 {
        (try server.commandTyped("BITPOS", key, bit ? "1" : "0")).asInt64OrNil ?? -1
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }
}

// MARK: - GeoKey

public struct GeoKey: Sendable {
    public enum Unit: String, Sendable { case m, km, mi, ft }

    public struct Location: Sendable, Hashable {
        public let member: String
        public let longitude: Double
        public let latitude: Double
    }

    public struct ScoredLocation: Sendable, Hashable {
        public let member: String
        public let distance: Double
        public let unit: Unit
    }

    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func add(longitude: Double, latitude: Double, member: String) throws -> Bool {
        let n = (try server.commandTyped(
            "GEOADD", key, String(longitude), String(latitude), member
        )).asInt64OrNil ?? 0
        return n == 1
    }

    public func position(_ members: String...) throws -> [Location?] {
        guard !members.isEmpty else { return [] }
        var args = ["GEOPOS", key]
        args.append(contentsOf: members)
        let items = (try server.commandTyped(args: args)).asArray
        return members.enumerated().map { (i, m) -> Location? in
            guard i < items.count else { return nil }
            let pair = items[i].asArray
            guard pair.count >= 2,
                  let lonStr = pair[0].asBulkOrNil, let lon = Double(lonStr),
                  let latStr = pair[1].asBulkOrNil, let lat = Double(latStr)
            else { return nil }
            return Location(member: m, longitude: lon, latitude: lat)
        }
    }

    public func distance(_ a: String, _ b: String, unit: Unit = .m) throws -> Double? {
        (try server.commandTyped("GEODIST", key, a, b, unit.rawValue)).asBulkOrNil.flatMap { Double($0) }
    }

    public func searchByRadius(
        longitude: Double, latitude: Double,
        radius: Double, unit: Unit = .m, count: Int64? = nil
    ) throws -> [String] {
        var args = [
            "GEOSEARCH", key,
            "FROMLONLAT", String(longitude), String(latitude),
            "BYRADIUS", String(radius), unit.rawValue,
            "ASC"
        ]
        if let c = count { args += ["COUNT", String(c)] }
        return (try server.commandTyped(args: args)).asArray.compactMap { $0.asBulkOrNil }
    }

    public func searchByRadiusWithDistances(
        longitude: Double, latitude: Double,
        radius: Double, unit: Unit = .m, count: Int64? = nil
    ) throws -> [ScoredLocation] {
        var args = [
            "GEOSEARCH", key,
            "FROMLONLAT", String(longitude), String(latitude),
            "BYRADIUS", String(radius), unit.rawValue,
            "ASC", "WITHCOORD", "WITHDIST"
        ]
        if let c = count { args += ["COUNT", String(c)] }
        let rows = (try server.commandTyped(args: args)).asArray
        return rows.compactMap { row -> ScoredLocation? in
            let arr = row.asArray
            guard arr.count >= 2,
                  let member = arr[0].asBulkOrNil,
                  let distStr = arr[1].asBulkOrNil, let dist = Double(distStr)
            else { return nil }
            return ScoredLocation(member: member, distance: dist, unit: unit)
        }
    }

    public func searchByRadiusOfMember(
        _ member: String, radius: Double, unit: Unit = .m, count: Int64? = nil
    ) throws -> [String] {
        var args = [
            "GEOSEARCH", key,
            "FROMMEMBER", member,
            "BYRADIUS", String(radius), unit.rawValue,
            "ASC"
        ]
        if let c = count { args += ["COUNT", String(c)] }
        return (try server.commandTyped(args: args)).asArray.compactMap { $0.asBulkOrNil }
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }
}

// MARK: - HyperLogLogKey

public struct HyperLogLogKey: Sendable {
    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func add(_ elements: String...) throws -> Bool {
        guard !elements.isEmpty else { return false }
        var args = ["PFADD", key]
        args.append(contentsOf: elements)
        return (try server.commandTyped(args: args)).asInt64OrNil == 1
    }

    public func count() throws -> Int64 {
        (try server.commandTyped("PFCOUNT", key)).asInt64OrNil ?? 0
    }

    public func unionCount(_ otherKeys: String...) throws -> Int64 {
        var args = ["PFCOUNT", key]
        args.append(contentsOf: otherKeys)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func merge(_ sources: String...) throws -> Bool {
        guard !sources.isEmpty else { return false }
        var args = ["PFMERGE", key]
        args.append(contentsOf: sources)
        let r = try server.commandTyped(args: args)
        if case .simpleString(let v) = r { return v == "OK" }
        return false
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }
}

// MARK: - StreamKey

public struct StreamKey: Sendable {
    public struct Entry: Sendable {
        public let id: String
        public let fields: [(String, String)]   // preserves insertion order
    }
    public enum TrimStrategy: Sendable { case approx, exact }

    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func add(
        fields: [(String, String)],
        maxLen: Int64? = nil,
        trimStrategy: TrimStrategy = .approx,
        id: String = "*"
    ) throws -> String? {
        guard !fields.isEmpty else { return nil }
        var args = ["XADD", key]
        if let maxLen = maxLen {
            args += ["MAXLEN", trimStrategy == .approx ? "~" : "=", String(maxLen)]
        }
        args.append(id)
        for (k, v) in fields { args += [k, v] }
        return (try server.commandTyped(args: args)).asBulkOrNil
    }

    public func length() throws -> Int64 {
        (try server.commandTyped("XLEN", key)).asInt64OrNil ?? 0
    }

    public func range(start: String = "-", end: String = "+", count: Int64? = nil) throws -> [Entry] {
        var args = ["XRANGE", key, start, end]
        if let c = count { args += ["COUNT", String(c)] }
        return try decodeEntries(server.commandTyped(args: args))
    }

    public func revRange(end: String = "+", start: String = "-", count: Int64? = nil) throws -> [Entry] {
        var args = ["XREVRANGE", key, end, start]
        if let c = count { args += ["COUNT", String(c)] }
        return try decodeEntries(server.commandTyped(args: args))
    }

    @discardableResult
    public func trim(maxLen: Int64, strategy: TrimStrategy = .approx) throws -> Int64 {
        let flag = strategy == .approx ? "~" : "="
        return (try server.commandTyped("XTRIM", key, "MAXLEN", flag, String(maxLen))).asInt64OrNil ?? 0
    }

    /// XDEL key id [id …] — delete specific entries by their IDs.
    /// Returns the number of entries actually removed.
    @discardableResult
    public func delete(ids: String...) throws -> Int64 {
        guard !ids.isEmpty else { return 0 }
        var args = ["XDEL", key]
        args.append(contentsOf: ids)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    /// EXISTS key — true if the stream currently exists.
    public func exists() throws -> Bool {
        (try server.commandTyped("EXISTS", key)).asInt64OrNil == 1
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }

    private func decodeEntries(_ reply: RespValue) throws -> [Entry] {
        var out: [Entry] = []
        for item in reply.asArray {
            let pair = item.asArray
            guard pair.count >= 2, let id = pair[0].asBulkOrNil else { continue }
            let fieldItems = pair[1].asArray
            var fields: [(String, String)] = []
            var i = 0
            while i < fieldItems.count - 1 {
                let k = fieldItems[i].asBulkOrNil ?? ""
                let v = fieldItems[i + 1].asBulkOrNil ?? ""
                fields.append((k, v))
                i += 2
            }
            out.append(Entry(id: id, fields: fields))
        }
        return out
    }
}

// MARK: - SortedSetKey

public struct SortedSetKey: Sendable {
    public struct ScoredMember: Sendable, Equatable {
        public let member: String
        public let score: Double
    }

    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func add(score: Double, member: String) throws -> Bool {
        (try server.commandTyped("ZADD", key, String(score), member)).asInt64OrNil == 1
    }

    @discardableResult
    public func addAll(_ members: [String: Double]) throws -> Int64 {
        guard !members.isEmpty else { return 0 }
        var args = ["ZADD", key]
        for (m, s) in members { args += [String(s), m] }
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    public func score(_ member: String) throws -> Double? {
        (try server.commandTyped("ZSCORE", key, member)).asBulkOrNil.flatMap { Double($0) }
    }

    public func rangeByScore(min: Double, max: Double) throws -> [String] {
        let args = ["ZRANGEBYSCORE", key, formatScore(min), formatScore(max)]
        return (try server.commandTyped(args: args)).asArray.compactMap { $0.asBulkOrNil }
    }

    /// Snapshot-typed ZRANGEBYSCORE — `[min, max]` inclusive, ascending
    /// by score. Falls back to `rangeByScore` on a snapshot miss. Drops
    /// ~80-150 µs per call vs the RESP path.
    public func rangeByScoreDirect(min: Double, max: Double) throws -> [String] {
        if let hit = server.directZrangeByScore(key, min: min, max: max) { return hit }
        return try rangeByScore(min: min, max: max)
    }

    public func rangeByScoreWithScores(min: Double, max: Double) throws -> [ScoredMember] {
        let args = ["ZRANGEBYSCORE", key, formatScore(min), formatScore(max), "WITHSCORES"]
        let items = (try server.commandTyped(args: args)).asArray
        var out: [ScoredMember] = []
        var i = 0
        while i < items.count - 1 {
            let m = items[i].asBulkOrNil ?? ""
            let s = Double(items[i + 1].asBulkOrNil ?? "") ?? 0
            out.append(ScoredMember(member: m, score: s))
            i += 2
        }
        return out
    }

    public func cardinality() throws -> Int64 {
        (try server.commandTyped("ZCARD", key)).asInt64OrNil ?? 0
    }

    /// ZRANK key member — 0-based rank of [member] in ascending order.
    /// Returns nil if [member] is not in the set.
    public func rank(_ member: String) throws -> Int64? {
        (try server.commandTyped("ZRANK", key, member)).asInt64OrNil
    }

    /// ZREVRANK key member — 0-based rank in descending order.
    public func revRank(_ member: String) throws -> Int64? {
        (try server.commandTyped("ZREVRANK", key, member)).asInt64OrNil
    }

    /// ZRANGE key start stop — members by ascending-rank index range.
    /// Negative indices count from the end.
    public func range(_ start: Int64, _ stop: Int64) throws -> [String] {
        let args = ["ZRANGE", key, String(start), String(stop)]
        return (try server.commandTyped(args: args)).asArray.compactMap { $0.asBulkOrNil }
    }

    /// ZRANGE key start stop WITHSCORES.
    public func rangeWithScores(_ start: Int64, _ stop: Int64) throws -> [ScoredMember] {
        let args = ["ZRANGE", key, String(start), String(stop), "WITHSCORES"]
        let items = (try server.commandTyped(args: args)).asArray
        var out: [ScoredMember] = []
        var i = 0
        while i + 1 < items.count {
            let m = items[i].asBulkOrNil ?? ""
            let s = Double(items[i + 1].asBulkOrNil ?? "") ?? 0
            out.append(ScoredMember(member: m, score: s))
            i += 2
        }
        return out
    }

    /// ZINCRBY key delta member — atomic score bump. Returns the new score.
    @discardableResult
    public func incrBy(_ member: String, _ delta: Double) throws -> Double {
        Double((try server.commandTyped("ZINCRBY", key, String(delta), member)).asBulkOrNil ?? "") ?? 0
    }

    /// ZCOUNT key min max — number of members with score in [min, max].
    public func count(min: Double, max: Double) throws -> Int64 {
        (try server.commandTyped("ZCOUNT", key, formatScore(min), formatScore(max))).asInt64OrNil ?? 0
    }

    /// ZREMRANGEBYSCORE key min max — drop every member whose score is in range.
    @discardableResult
    public func removeRangeByScore(min: Double, max: Double) throws -> Int64 {
        (try server.commandTyped("ZREMRANGEBYSCORE", key, formatScore(min), formatScore(max)))
            .asInt64OrNil ?? 0
    }

    @discardableResult
    public func remove(_ members: String...) throws -> Int64 {
        guard !members.isEmpty else { return 0 }
        var args = ["ZREM", key]
        args.append(contentsOf: members)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    /// EXISTS key — true if the sorted set currently exists.
    public func exists() throws -> Bool {
        (try server.commandTyped("EXISTS", key)).asInt64OrNil == 1
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }

    private func formatScore(_ s: Double) -> String {
        if s == .infinity { return "+inf" }
        if s == -.infinity { return "-inf" }
        return String(s)
    }
}

// MARK: - ListKey

public struct ListKey: Sendable {
    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func rpush(_ values: String...) throws -> Int64 {
        guard !values.isEmpty else { return 0 }
        var args = ["RPUSH", key]
        args.append(contentsOf: values)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func lpush(_ values: String...) throws -> Int64 {
        guard !values.isEmpty else { return 0 }
        var args = ["LPUSH", key]
        args.append(contentsOf: values)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    public func range(_ start: Int64, _ stop: Int64) throws -> [String] {
        let args = ["LRANGE", key, String(start), String(stop)]
        return (try server.commandTyped(args: args)).asArray.compactMap { $0.asBulkOrNil }
    }

    public func length() throws -> Int64 {
        (try server.commandTyped("LLEN", key)).asInt64OrNil ?? 0
    }

    /// LPOP key — remove and return the head. Null when the list is empty.
    public func lpop() throws -> String? {
        (try server.commandTyped("LPOP", key)).asBulkOrNil
    }

    /// RPOP key — remove and return the tail. Null when the list is empty.
    public func rpop() throws -> String? {
        (try server.commandTyped("RPOP", key)).asBulkOrNil
    }

    /// LINDEX key index — 0-based, negative indices count from the tail.
    public func index(_ idx: Int64) throws -> String? {
        (try server.commandTyped("LINDEX", key, String(idx))).asBulkOrNil
    }

    /// LSET key index value — throws `commandFailed` if the index is out of range.
    @discardableResult
    public func set(_ idx: Int64, _ value: String) throws -> Bool {
        let r = try server.commandTyped("LSET", key, String(idx), value)
        if case .simpleString(let v) = r { return v == "OK" }
        return false
    }

    /// LTRIM key start stop — keep only the range [start, stop]. Returns
    /// true on OK (the command itself cannot fail on an empty list).
    @discardableResult
    public func trim(_ start: Int64, _ stop: Int64) throws -> Bool {
        let r = try server.commandTyped("LTRIM", key, String(start), String(stop))
        if case .simpleString(let v) = r { return v == "OK" }
        return false
    }

    /// LREM key count value — remove [count] occurrences of [value].
    /// count > 0: head→tail. count < 0: tail→head. count = 0: all.
    @discardableResult
    public func remove(count: Int64, value: String) throws -> Int64 {
        (try server.commandTyped("LREM", key, String(count), value)).asInt64OrNil ?? 0
    }

    /// EXISTS key — true if the list currently exists.
    public func exists() throws -> Bool {
        (try server.commandTyped("EXISTS", key)).asInt64OrNil == 1
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }
}

// MARK: - StringKey

public struct StringKey: Sendable {
    public let key: String
    internal let server: DazzleServer

    /// Options for SET: NX (only if absent), XX (only if present), EX/PX (TTL).
    public struct SetOptions: Sendable, Hashable {
        public var onlyIfAbsent: Bool    // NX
        public var onlyIfPresent: Bool   // XX
        public var ttlSeconds: Int64?    // EX
        public var ttlMillis: Int64?     // PX

        public init(
            onlyIfAbsent: Bool = false,
            onlyIfPresent: Bool = false,
            ttlSeconds: Int64? = nil,
            ttlMillis: Int64? = nil
        ) {
            self.onlyIfAbsent = onlyIfAbsent
            self.onlyIfPresent = onlyIfPresent
            self.ttlSeconds = ttlSeconds
            self.ttlMillis = ttlMillis
        }
    }

    /// SET key value [EX seconds | PX ms] [NX | XX].
    /// Returns true if the write happened, false if an NX/XX guard
    /// blocked it.
    @discardableResult
    public func set(_ value: String, options: SetOptions = SetOptions()) throws -> Bool {
        var args = ["SET", key, value]
        if let s = options.ttlSeconds { args += ["EX", String(s)] }
        if let m = options.ttlMillis  { args += ["PX", String(m)] }
        if options.onlyIfAbsent       { args += ["NX"] }
        if options.onlyIfPresent      { args += ["XX"] }
        let reply = try server.commandTyped(args: args)
        // NX/XX rejection replies null-bulk; OK replies +OK.
        switch reply {
        case .simpleString(let v): return v == "OK"
        case .bulk(let b):         return b != nil
        default:                   return false
        }
    }

    public func get() throws -> String? {
        (try server.commandTyped("GET", key)).asBulkOrNil
    }

    /// Snapshot-typed GET — returns the value from the in-process cache
    /// without encoding / parsing RESP. Falls back to `get` on a miss.
    /// Only the simple `SET key value` form (no EX/PX/XX/NX) hits the
    /// snapshot — richer flavours go through the pipe.
    public func getDirect() throws -> String? {
        if let hit = server.directGetString(key) { return hit }
        return try get()
    }

    /// APPEND key value — returns the new total length.
    @discardableResult
    public func append(_ value: String) throws -> Int64 {
        (try server.commandTyped("APPEND", key, value)).asInt64OrNil ?? 0
    }

    /// STRLEN key — length in bytes, 0 if absent.
    public func length() throws -> Int64 {
        (try server.commandTyped("STRLEN", key)).asInt64OrNil ?? 0
    }

    /// INCR key — atomic integer +1, creating the key as `0` first if absent.
    @discardableResult
    public func incr() throws -> Int64 {
        (try server.commandTyped("INCR", key)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func incrBy(_ delta: Int64) throws -> Int64 {
        (try server.commandTyped("INCRBY", key, String(delta))).asInt64OrNil ?? 0
    }

    /// INCRBYFLOAT key delta — works against a string holding a float.
    @discardableResult
    public func incrByFloat(_ delta: Double) throws -> Double {
        Double((try server.commandTyped("INCRBYFLOAT", key, String(delta))).asBulkOrNil ?? "") ?? 0
    }

    /// DECR key — atomic integer -1.
    @discardableResult
    public func decr() throws -> Int64 {
        (try server.commandTyped("DECR", key)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func decrBy(_ delta: Int64) throws -> Int64 {
        (try server.commandTyped("DECRBY", key, String(delta))).asInt64OrNil ?? 0
    }

    /// EXISTS key — true if the key currently exists.
    public func exists() throws -> Bool {
        (try server.commandTyped("EXISTS", key)).asInt64OrNil == 1
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }
}

// MARK: - SetKey

public struct SetKey: Sendable {
    public let key: String
    internal let server: DazzleServer

    @discardableResult
    public func add(_ members: String...) throws -> Int64 {
        guard !members.isEmpty else { return 0 }
        var args = ["SADD", key]
        args.append(contentsOf: members)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    public func contains(_ member: String) throws -> Bool {
        (try server.commandTyped("SISMEMBER", key, member)).asInt64OrNil == 1
    }

    public func members() throws -> Set<String> {
        Set((try server.commandTyped("SMEMBERS", key)).asArray.compactMap { $0.asBulkOrNil })
    }

    /// Snapshot-typed SMEMBERS — reads set members from the in-process
    /// cache without encoding / parsing RESP. Falls back to `members`
    /// on a snapshot miss. Drops ~60-100 µs per call on records hot in
    /// the cache; used by `DazzleContextStore.byTag` / `byTags`.
    public func membersDirect() throws -> Set<String> {
        if let hit = server.directSmembers(key) { return Set(hit) }
        return try members()
    }

    public func cardinality() throws -> Int64 {
        (try server.commandTyped("SCARD", key)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func remove(_ members: String...) throws -> Int64 {
        guard !members.isEmpty else { return 0 }
        var args = ["SREM", key]
        args.append(contentsOf: members)
        return (try server.commandTyped(args: args)).asInt64OrNil ?? 0
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        (try server.commandTyped("DEL", key)).asInt64OrNil == 1
    }
}
