// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Dazzle-backed implementation of `ContextStore`.
///
/// Key namespace layout for a store named `"sensors"`:
///
/// | Purpose      | Key pattern                 | Primitive       |
/// |--------------|-----------------------------|-----------------|
/// | Record       | `cs:sensors:rec:<id>`       | HashKey         |
/// | Time index   | `cs:sensors:idx:time`       | SortedSetKey    |
/// | Tag index    | `cs:sensors:idx:tag:<tag>`  | SetKey          |
/// | Vector index | FT `cs_sensors_vec`         | valkey-search   |
public final class DazzleContextStore<T>: ContextStore, @unchecked Sendable where T: Sendable {

    public let name: String
    private let dazzle: Dazzle
    private let ns: Dazzle  // prefixed view: cs:<name>:
    private let encoder: @Sendable (T) -> [String: String]
    private let decoder: @Sendable ([String: String]) -> T?
    private let embedder: (@Sendable (T) -> [Float])?
    private let embeddingDim: Int?
    private let timeExtractor: (@Sendable (T) -> Int64)?
    private let tagsExtractor: (@Sendable (T) -> Set<String>)?
    private let vectorIndex: VectorIndex?

    private let embeddingField = "_embedding"
    private let timeIndexKey = "idx:time"
    private let lock = NSLock()
    private var isClosed = false

    internal init(
        dazzle: Dazzle,
        name: String,
        encoder: @escaping @Sendable (T) -> [String: String],
        decoder: @escaping @Sendable ([String: String]) -> T?,
        embedder: (@Sendable (T) -> [Float])? = nil,
        embeddingDim: Int? = nil,
        embedAlgorithm: VectorIndex.Algorithm = .hnsw,
        embedMetric: VectorIndex.Metric = .cosine,
        timeExtractor: (@Sendable (T) -> Int64)? = nil,
        tagsExtractor: (@Sendable (T) -> Set<String>)? = nil
    ) {
        self.dazzle = dazzle
        self.name = name
        self.ns = dazzle.namespace("cs:\(name)")
        self.encoder = encoder
        self.decoder = decoder
        self.embedder = embedder
        self.embeddingDim = embeddingDim
        self.timeExtractor = timeExtractor
        self.tagsExtractor = tagsExtractor

        if let dim = embeddingDim {
            let idx = DazzleServer.shared.vectorIndex(
                name: "cs_\(name.replacingOccurrences(of: ":", with: "_"))_vec",
                hashPrefix: "cs:\(name):rec:",
                vectorField: "_embedding",
                dim: dim,
                algorithm: embedAlgorithm,
                metric: embedMetric
            )
            _ = idx.create()
            self.vectorIndex = idx
        } else {
            self.vectorIndex = nil
        }
    }

    // ── Storage ─────────────────────────────────────────────────────────

    public func put(id: String, value: T) throws {
        try checkOpen()
        if id.isEmpty {
            throw DazzleError.transportError("id must not be empty")
        }

        let fields = encoder(value)
        if fields[embeddingField] != nil {
            throw DazzleError.transportError(
                "encode() returned reserved field name '\(embeddingField)' — rename it"
            )
        }

        if let vi = vectorIndex, let embed = embedder {
            let vec = embed(value)
            vi.add(id: "cs:\(name):rec:\(id)", vector: vec, metadata: fields)
        } else {
            let hash = ns.hash(recordKey(id))
            if !fields.isEmpty { _ = try hash.setAll(fields) }
        }

        if let extract = timeExtractor {
            _ = try ns.sortedSet(timeIndexKey).add(score: Double(extract(value)), member: id)
        }
        if let extract = tagsExtractor {
            for tag in extract(value) {
                _ = try ns.set(tagIndexKey(tag)).add(id)
            }
        }
    }

    public func putAll(_ entries: [String: T]) throws {
        for (id, value) in entries { try put(id: id, value: value) }
    }

    public func get(id: String) -> T? {
        guard (try? checkOpen()) != nil else { return nil }
        // Phase 7 — snapshot-typed HGETALL when the record is hot in the
        // in-process cache; falls back to the pipe path automatically on
        // a miss. Skips RESP encode (C side) + Resp parser walk (Swift
        // side), which was the single largest regression ContextStore
        // took when it was unified on the generic `commandTyped` path.
        let raw: [String: String]
        do { raw = try ns.hash(recordKey(id)).getAllDirect() } catch { return nil }
        if raw.isEmpty { return nil }
        let clean = raw.filter { $0.key != embeddingField }
        return decoder(clean)
    }

    public func getAll(ids: [String]) -> [T?] { ids.map { get(id: $0) } }

    public func delete(id: String) -> Bool {
        guard (try? checkOpen()) != nil else { return false }
        let hash = ns.hash(recordKey(id))
        // No hash-level `exists()` on Swift HashKey — probe via getAll.
        let existed = (try? hash.getAll())?.isEmpty == false
        guard existed else { return false }

        if timeExtractor != nil {
            _ = try? ns.sortedSet(timeIndexKey).remove(id)
        }
        if let extract = tagsExtractor, let value = get(id: id) {
            for tag in extract(value) {
                _ = try? ns.set(tagIndexKey(tag)).remove(id)
            }
        }
        _ = try? hash.deleteKey()
        return true
    }

    public func flush() throws {
        try checkOpen()
        let scanIter = ns.scan(match: "rec:*", count: 200)
        while let batch = scanIter.next() {
            for fullKey in batch { _ = try? dazzle.hash(fullKey).deleteKey() }
        }
        _ = try? ns.sortedSet(timeIndexKey).deleteKey()
        let tagIter = ns.scan(match: "idx:tag:*", count: 200)
        while let batch = tagIter.next() {
            for fullKey in batch { _ = try? dazzle.set(fullKey).deleteKey() }
        }
        _ = vectorIndex?.drop()
        _ = vectorIndex?.create()
    }

    public func count() throws -> Int64 {
        try checkOpen()
        var total: Int64 = 0
        let iter = ns.scan(match: "rec:*", count: 500)
        while let batch = iter.next() { total += Int64(batch.count) }
        return total
    }

    public func iterate(match: String?) -> AnyIterator<(String, T)> {
        let pattern = match.map { "rec:\($0)" } ?? "rec:*"
        let scanIter = ns.scan(match: pattern, count: 200)
        var pending: [(String, T)] = []
        let nsPrefixValue = "cs:\(name):rec:"

        return AnyIterator { [weak self] in
            guard let self = self else { return nil }
            while pending.isEmpty {
                guard let batch = scanIter.next() else { return nil }
                for fullKey in batch {
                    let id = fullKey.hasPrefix(nsPrefixValue)
                        ? String(fullKey.dropFirst(nsPrefixValue.count))
                        : fullKey
                    guard let raw = try? self.dazzle.hash(fullKey).getAll(), !raw.isEmpty else { continue }
                    let clean = raw.filter { $0.key != self.embeddingField }
                    if let decoded = self.decoder(clean) {
                        pending.append((id, decoded))
                    }
                }
            }
            return pending.removeFirst()
        }
    }

    // ── Queries ─────────────────────────────────────────────────────────

    public func semanticSearch(query: String, k: Int) -> [Hit<T>] {
        // Text queries require a String→vector embedder, which is separate
        // from the T→vector embedder this store holds. The caller should
        // use the vector-based overload instead. Kept as a no-op for
        // consistency with the Kotlin surface.
        return []
    }

    public func semanticSearch(vector: [Float], k: Int) -> [Hit<T>] {
        guard let vi = vectorIndex, let dim = embeddingDim else { return [] }
        precondition(vector.count == dim,
            "query vector has \(vector.count) dims, store was built with \(dim)")
        let raw = vi.search(query: vector, k: k)
        let prefix = "cs:\(name):rec:"
        return raw.compactMap { r in
            let id = r.id.hasPrefix(prefix) ? String(r.id.dropFirst(prefix.count)) : r.id
            guard let value = get(id: id) else { return nil }
            return Hit(id: id, score: r.score, value: value)
        }
    }

    public func byTimeRange(start: Int64, end: Int64, limit: Int) -> [(String, T)] {
        guard timeExtractor != nil else { return [] }
        // Phase 2 — rangeByScoreDirect reads from the snapshot cache
        // without the RESP round-trip; falls back to rangeByScore on
        // miss.
        let ids = (try? ns.sortedSet(timeIndexKey).rangeByScoreDirect(min: Double(start), max: Double(end))) ?? []
        return ids.prefix(limit).compactMap { id -> (String, T)? in
            guard let v = get(id: id) else { return nil }
            return (id, v)
        }
    }

    public func byTag(_ tag: String) -> AnyIterator<(String, T)> {
        guard tagsExtractor != nil else { return AnyIterator { nil } }
        // Phase 2 — membersDirect reads from the snapshot cache.
        let members = (try? ns.set(tagIndexKey(tag)).membersDirect()) ?? []
        var it = members.makeIterator()
        return AnyIterator { [weak self] in
            guard let self = self else { return nil }
            while let id = it.next() {
                if let v = self.get(id: id) { return (id, v) }
            }
            return nil
        }
    }

    public func byTags(allOf: Set<String>) -> AnyIterator<(String, T)> {
        guard tagsExtractor != nil, !allOf.isEmpty else { return AnyIterator { nil } }
        let sets = allOf.map { ns.set(tagIndexKey($0)) }
        let smallest = sets.min(by: {
            ((try? $0.cardinality()) ?? 0) < ((try? $1.cardinality()) ?? 0)
        }) ?? sets[0]
        let members = (try? smallest.membersDirect()) ?? []
        var it = members.makeIterator()
        return AnyIterator { [weak self] in
            guard let self = self else { return nil }
            while let id = it.next() {
                let inAll = sets.allSatisfy { (try? $0.contains(id)) == true }
                if inAll, let v = self.get(id: id) { return (id, v) }
            }
            return nil
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private func recordKey(_ id: String) -> String { "rec:\(id)" }
    private func tagIndexKey(_ tag: String) -> String { "idx:tag:\(tag)" }

    private func checkOpen() throws {
        lock.lock(); defer { lock.unlock() }
        if isClosed {
            throw DazzleError.transportError("ContextStore '\(name)' is closed")
        }
    }
}
