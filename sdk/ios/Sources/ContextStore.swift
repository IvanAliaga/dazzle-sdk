// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Generic typed record store for LLM-agent context.
///
/// Domain-agnostic — the dev brings `T` and an encode/decode pair;
/// the SDK handles persistence, optional semantic / time-range / tag
/// indices on top of Valkey primitives (HashKey, SortedSetKey, SetKey,
/// VectorIndex).
public protocol ContextStore<T>: AnyObject, ContextStoreBox, Sendable {
    associatedtype T

    /// Logical name — used as a Valkey key-prefix.
    var name: String { get }

    // ── Storage ─────────────────────────────────────────────────────────

    func put(id: String, value: T) throws
    func putAll(_ entries: [String: T]) throws
    func get(id: String) -> T?
    func getAll(ids: [String]) -> [T?]
    func delete(id: String) -> Bool
    func flush() throws
    func count() throws -> Int64
    /// Iterate every record; `match` is a Valkey SCAN pattern against the id.
    func iterate(match: String?) -> AnyIterator<(String, T)>

    // ── Queries — empty / no-op if the index was not declared ──────────

    func semanticSearch(query: String, k: Int) -> [Hit<T>]
    func semanticSearch(vector: [Float], k: Int) -> [Hit<T>]
    func byTimeRange(start: Int64, end: Int64, limit: Int) -> [(String, T)]
    func byTag(_ tag: String) -> AnyIterator<(String, T)>
    func byTags(allOf: Set<String>) -> AnyIterator<(String, T)>

    func close()
}

public extension ContextStore {
    func iterate() -> AnyIterator<(String, T)> { iterate(match: nil) }
    func semanticSearch(query: String) -> [Hit<T>] { semanticSearch(query: query, k: 10) }
    func semanticSearch(vector: [Float]) -> [Hit<T>] { semanticSearch(vector: vector, k: 10) }
    func byTimeRange(start: Int64, end: Int64) -> [(String, T)] { byTimeRange(start: start, end: end, limit: 1000) }
}

/// A search result: the retrieved value plus its similarity score.
public struct Hit<T>: Sendable where T: Sendable {
    public let id: String
    /// Raw distance from the vector index (lower = closer for L2 / cosine).
    public let score: Float
    public let value: T

    public init(id: String, score: Float, value: T) {
        self.id = id
        self.score = score
        self.value = value
    }
}
