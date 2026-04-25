// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:dazzle_samples_shared/dazzle_samples_shared.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Loads `assets/dazzle_faq.json` into a Dazzle HNSW_SQ8 vector index
/// on first launch. Uses the shared `miniEmbed` hash-bucket embedder so
/// the demo has no second model weight to ship — swap in a real
/// embedder (BGE-small via llama.cpp --embedding, or a server-side
/// Inference API) for production.
class KbCorpus {
  static const String indexName    = 'kb';
  static const String hashPrefix   = 'samples:kb:';
  static const int    embeddingDim = 384;

  static bool _loaded = false;
  static Map<String, FaqEntry> _byKey = const {};

  static Future<void> loadIntoDazzle() async {
    if (_loaded) return;
    final raw = await rootBundle.loadString('assets/dazzle_faq.json');
    final faqs = (jsonDecode(raw) as List)
        .cast<Map<String, dynamic>>()
        .map(FaqEntry.fromJson)
        .toList();

    // Create (or open, if it already exists — `VectorIndex.create` is
    // idempotent on the Dazzle side).
    final idx = DazzleServer.shared.vectorIndex(
      name: indexName,
      hashPrefix: hashPrefix,
      vectorField: 'emb',
      dim: embeddingDim,
      algorithm: VectorAlgorithm.hnswSq8,
      metric: VectorMetric.cosine,
      initialCapacity: faqs.length,
    );

    final ids = <String>[];
    final vectors = <List<double>>[];
    for (final f in faqs) {
      ids.add('$hashPrefix${f.id}');
      vectors.add(miniEmbed('${f.question} ${f.answer}', dim: embeddingDim));
    }
    idx.addBatchDirect(ids, vectors);

    _byKey = {for (final f in faqs) '$hashPrefix${f.id}': f};
    _loaded = true;
  }

  static FaqEntry? entry(String key) => _byKey[key];
}

class FaqEntry {
  const FaqEntry({
    required this.id,
    required this.category,
    required this.question,
    required this.answer,
  });

  final String id;
  final String category;
  final String question;
  final String answer;

  factory FaqEntry.fromJson(Map<String, dynamic> j) => FaqEntry(
        id:       j['id']       as String,
        category: j['category'] as String,
        question: j['question'] as String,
        answer:   j['answer']   as String,
      );
}
