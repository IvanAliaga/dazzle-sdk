// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:dazzle_samples_shared/dazzle_samples_shared.dart';

import 'kb_corpus.dart';

/// Tool the LLM calls when the user asks about Dazzle itself.
///
/// Wire-format (OpenAI-compatible):
/// ```
/// search_kb(query: string, k: integer)
///   → [{id, category, question, answer, score}]
/// ```
class SearchKbTool extends Tool<SearchQuery, List<Map<String, Object>>> {
  @override
  String get name => 'search_kb';

  @override
  String get description =>
      'Look up the top-k most relevant Dazzle FAQ rows for a natural-'
      'language query. Use this whenever the user asks about Dazzle '
      'the product, the SDK API, the four LLM adapters, the '
      'benchmarks, or the HNSW variants. Returns the FAQ question, '
      'full answer, and a similarity score (lower is closer).';

  @override
  JsonSchema get argsSchema => jsonSchemaObject(
        description: 'Semantic search over the on-device Dazzle FAQ.',
        build: (b) {
          b.property('query',
              type: 'string',
              description: "The user's question, verbatim or paraphrased.",
              required: true);
          b.property('k',
              type: 'integer',
              description: 'Number of FAQ rows to return (1..10).',
              required: false,
              minimum: 1,
              maximum: 10);
        },
      );

  @override
  SearchQuery argsFromJson(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return SearchQuery(
      query: m['query'] as String,
      k: (m['k'] as num?)?.toInt(),
    );
  }

  @override
  Future<List<Map<String, Object>>> invoke(
      SearchQuery args, ToolContext ctx) async {
    final k = (args.k ?? 5).clamp(1, 10);
    final vec = miniEmbed(args.query, dim: KbCorpus.embeddingDim);

    final idx = DazzleServer.shared.vectorIndex(
          name: KbCorpus.indexName,
          hashPrefix: KbCorpus.hashPrefix,
          vectorField: 'emb',
          dim: KbCorpus.embeddingDim,
          algorithm: VectorAlgorithm.hnswSq8,
          metric: VectorMetric.cosine,
        );
    final hits = idx.searchDirect(vec, k: k, efRuntime: 10);

    return [
      for (final h in hits)
        if (KbCorpus.entry(h.id) case final e?)
          <String, Object>{
            'id':       e.id,
            'category': e.category,
            'question': e.question,
            'answer':   e.answer,
            'score':    h.distance,
          },
    ];
  }

  @override
  String returnToJson(List<Map<String, Object>> value) => jsonEncode(value);
}

/// Arguments the LLM sends when it calls `search_kb`.
class SearchQuery {
  const SearchQuery({required this.query, this.k});
  final String query;
  final int?   k;
}
