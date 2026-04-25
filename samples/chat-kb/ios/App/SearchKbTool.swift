// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Tool the LLM calls when the user asks about Dazzle itself.
///
/// Signature (OpenAI-compatible):
/// ```
/// search_kb(query: string, k: integer)
///   → [{id, category, question, answer, score}]
/// ```
struct SearchKbTool: Tool {
    typealias Args = SearchQuery
    typealias Ret  = [FaqHit]

    let name        = "search_kb"
    let description = """
        Look up the top-k most relevant Dazzle FAQ rows for a natural-
        language query. Use this whenever the user asks about Dazzle
        the product, the SDK API, the four LLM adapters, the benchmarks,
        or the HNSW variants. Returns the FAQ question, full answer,
        and a similarity score (lower is closer).
        """

    let argsSchema: JsonSchema = jsonSchemaObject(
        description: "Semantic search over the on-device Dazzle FAQ."
    ) {
        $0.property("query", type: "string",
                    description: "The user's question, verbatim or paraphrased.",
                    required: true)
        $0.property("k", type: "integer",
                    description: "Number of FAQ rows to return (1..10).",
                    required: false,
                    minimum: 1, maximum: 10)
    }

    func argsFromJson(_ raw: String) throws -> SearchQuery {
        let data = Data(raw.utf8)
        return try JSONDecoder().decode(SearchQuery.self, from: data)
    }

    func invoke(args: SearchQuery, ctx: ToolContext) async throws -> [FaqHit] {
        let k = max(1, min(10, args.k ?? 5))
        let vec = miniEmbed(args.query)

        let server = DazzleServer.shared
        let idx = server.vectorIndex(
            name:        KbCorpus.indexName,
            hashPrefix:  KbCorpus.hashPrefix,
            vectorField: "emb",
            dim:         KbCorpus.embeddingDim,
            algorithm:   .hnswSq8,
            metric:      .cosine
        )
        let results = idx.searchDirect(query: vec, k: k, efRuntime: 10)

        var hits: [FaqHit] = []
        for r in results {
            if let entry = await MainActor.run(body: {
                KbCorpus.entry(forKey: r.id)
            }) {
                hits.append(FaqHit(
                    id:       entry.id,
                    category: entry.category,
                    question: entry.question,
                    answer:   entry.answer,
                    score:    r.distance
                ))
            }
        }
        return hits
    }

    func returnToJson(_ value: [FaqHit]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }
}

struct SearchQuery: Codable, Sendable {
    let query: String
    let k:     Int?
}

struct FaqHit: Codable, Sendable {
    let id:       String
    let category: String
    let question: String
    let answer:   String
    let score:    Float
}
