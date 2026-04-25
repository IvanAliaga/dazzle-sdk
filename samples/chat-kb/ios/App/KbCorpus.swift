// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Loads the bundled `dazzle_faq.json` knowledge base into a Dazzle
/// HNSW_SQ8 vector index on first boot.
enum KbCorpus {

    static let indexName      = "kb"
    static let hashPrefix     = "samples:kb:"
    static let embeddingDim   = 384

    @MainActor private static var index: VectorIndex?
    @MainActor private static var entries: [FaqEntry] = []

    static func loadIntoDazzle() async throws {
        if let cached = await currentIndex(), !cached.isEmpty() { return }

        let url = Bundle.main.url(forResource: "dazzle_faq", withExtension: "json")
        guard let url = url else {
            throw NSError(
                domain: "KbCorpus", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "dazzle_faq.json not bundled — check the Resources build phase"])
        }
        let data = try Data(contentsOf: url)
        let faqs = try JSONDecoder().decode([FaqEntry].self, from: data)

        let server = DazzleServer.shared
        let idx = server.vectorIndex(
            name:        indexName,
            hashPrefix:  hashPrefix,
            vectorField: "emb",
            dim:         embeddingDim,
            algorithm:   .hnswSq8,
            metric:      .cosine
        )
        guard idx.create() else {
            throw NSError(domain: "KbCorpus", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "vector index create failed"])
        }

        let ids: [String]       = faqs.map { "\(hashPrefix)\($0.id)" }
        let vectors: [[Float]]  = faqs.map { miniEmbed("\($0.question) \($0.answer)") }
        idx.addBatchDirect(ids: ids, vectors: vectors)

        await setIndex(idx)
        await setEntries(faqs)
    }

    /// Convenience accessor for the loaded entries (used by the tool to
    /// translate id → row).
    @MainActor
    static func entry(forKey key: String) -> FaqEntry? {
        entries.first { "\(hashPrefix)\($0.id)" == key }
    }

    @MainActor private static func currentIndex() -> VectorIndex? { index }
    @MainActor private static func setIndex(_ v: VectorIndex)     { index = v }
    @MainActor private static func setEntries(_ e: [FaqEntry])    { entries = e }
}

// MARK: – Model

struct FaqEntry: Codable, Hashable {
    let id:       String
    let category: String
    let question: String
    let answer:   String
}

// MARK: – Minimal deterministic embedder
//
// Hash-bucket embedder: tokenise the input, bucket each token into
// `dim` slots via SipHash, L2-normalise. The resulting vectors cluster
// together for FAQ rows that share vocabulary — enough signal for this
// demo. For production, drop in a real embedder (BGE-small, E5-small,
// llama.cpp --embedding, or a server-side Inference API).
//
// This is NOT a contextual embedder. It's a bag-of-tokens vector with
// roughly TF weighting. It's 100% local and zero-dep.

/// Produce a dim=384 vector for `text`. Deterministic; same input
/// always hashes to the same vector.
func miniEmbed(_ text: String) -> [Float] {
    let dim = KbCorpus.embeddingDim
    var vec = [Float](repeating: 0, count: dim)

    let lowered = text.lowercased()
    let tokens  = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    guard !tokens.isEmpty else {
        vec[0] = 1  // avoid all-zero vectors
        return vec
    }

    for tok in tokens {
        // FNV-1a 64-bit hash — cheap, stable across runs.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in tok.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x00000100000001B3
        }
        let bucket  = Int(hash % UInt64(dim))
        let sign: Float = (hash >> 32) & 1 == 0 ? 1 : -1
        vec[bucket] += sign
    }

    // L2 normalise
    var norm: Float = 0
    for x in vec { norm += x * x }
    if norm > 0 {
        let inv = 1.0 / sqrt(norm)
        for i in 0..<dim { vec[i] *= inv }
    }
    return vec
}

private extension VectorIndex {
    /// We don't have a public `count()` helper; a cheap "is the index
    /// empty?" proxy is to search a dummy vector and check if anything
    /// comes back.
    func isEmpty() -> Bool {
        let probe = [Float](repeating: 0, count: 384)
        let hits = self.searchDirect(query: probe, k: 1, efRuntime: 10)
        return hits.isEmpty
    }
}
