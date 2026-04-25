// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Fluent builder for a `ContextStore<T>` bound to a Dazzle client namespace.
///
/// ```swift
/// let chat = dazzle.contextStore(
///     name: "chat:42",
///     T: ChatMessage.self,
///     encode: { m in ["role": m.role.rawValue, "text": m.text] },
///     decode: { f in
///         guard let role = f["role"], let text = f["text"] else { return nil }
///         return ChatMessage(role: Role(rawValue: role) ?? .user, text: text)
///     },
///     config: {
///         $0.semanticSearch(dim: 384) { m in embedder.embed(m.text) }
///         $0.timeRange { Int64($0.timestamp.timeIntervalSince1970) }
///         $0.tags { [$0.role.rawValue] }
///     }
/// )
/// ```
public final class ContextStoreBuilder<T: Sendable>: @unchecked Sendable {
    internal var embedder: (@Sendable (T) -> [Float])?
    internal var embeddingDim: Int?
    internal var embedAlgorithm: VectorIndex.Algorithm = .hnsw
    internal var embedMetric: VectorIndex.Metric = .cosine
    internal var timeExtractor: (@Sendable (T) -> Int64)?
    internal var tagsExtractor: (@Sendable (T) -> Set<String>)?

    /// Per-store execution override. When `nil`, inherits from `DazzleConfig`.
    public var execution: ExecutionPolicy?

    /// Declare semantic-search support for this store.
    public func semanticSearch(
        dim: Int,
        algorithm: VectorIndex.Algorithm = .hnsw,
        metric: VectorIndex.Metric = .cosine,
        embed: @escaping @Sendable (T) -> [Float]
    ) {
        precondition(dim > 0, "embedding dim must be positive")
        self.embeddingDim = dim
        self.embedAlgorithm = algorithm
        self.embedMetric = metric
        self.embedder = embed
    }

    /// Declare a timestamp extractor — enables `byTimeRange`.
    public func timeRange(_ extract: @escaping @Sendable (T) -> Int64) {
        timeExtractor = extract
    }

    /// Declare a tag extractor — enables `byTag` / `byTags`.
    public func tags(_ extract: @escaping @Sendable (T) -> Set<String>) {
        tagsExtractor = extract
    }
}

public extension Dazzle {
    /// Build a typed `ContextStore<T>` on top of this Dazzle client.
    ///
    /// - Parameters:
    ///   - name: stable logical identifier (key-prefix).
    ///   - encode: serialize `T` → flat `[String: String]`.
    ///   - decode: reconstruct `T` from stored fields (return `nil` on parse failure).
    ///   - config: optional block to declare index hooks.
    func contextStore<T: Sendable>(
        name: String,
        encode: @escaping @Sendable (T) -> [String: String],
        decode: @escaping @Sendable ([String: String]) -> T?,
        config: (ContextStoreBuilder<T>) -> Void = { _ in }
    ) -> DazzleContextStore<T> {
        let b = ContextStoreBuilder<T>()
        config(b)
        return DazzleContextStore<T>(
            dazzle: self,
            name: name,
            encoder: encode,
            decoder: decode,
            embedder: b.embedder,
            embeddingDim: b.embeddingDim,
            embedAlgorithm: b.embedAlgorithm,
            embedMetric: b.embedMetric,
            timeExtractor: b.timeExtractor,
            tagsExtractor: b.tagsExtractor
        )
    }
}
