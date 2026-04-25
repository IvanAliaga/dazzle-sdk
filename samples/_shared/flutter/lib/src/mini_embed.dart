// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Minimal deterministic embedder — FNV-1a hash-bucket "bag of tokens",
// L2-normalised. Matches samples/_shared/android/KbCorpus.kt::miniEmbed
// and samples/_shared/ios/KbCorpus.swift::miniEmbed exactly so the
// Flutter chat-kb sample returns the same FAQ hits as the native
// samples on the same corpus.
//
// This exists so the sample runs with zero extra downloads. For
// production, swap in a real embedder (BGE-small via llama.cpp
// --embedding, or a server-side Inference API).

import 'dart:math' show sqrt;
import 'dart:typed_data';

List<double> miniEmbed(String text, {int dim = 384}) {
  final vec = Float32List(dim);

  final tokens = text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  if (tokens.isEmpty) {
    vec[0] = 1.0;
    return List<double>.from(vec);
  }

  for (final tok in tokens) {
    // FNV-1a, 64-bit. Dart int is 64-bit on the VM but the BigInt-ish
    // semantics in JS are different — the samples only build for the
    // VM targets so this is fine.
    var hash = 0xcbf29ce484222325;
    for (final byte in tok.codeUnits) {
      hash ^= byte & 0xFF;
      hash = _mulFnv64(hash, 0x00000100000001B3);
    }
    final bucket = (hash.toUnsigned(64) % BigInt.from(dim).toInt()).toInt();
    final signBit = (hash >> 32) & 1;
    final sign = signBit == 0 ? 1.0 : -1.0;
    vec[bucket] += sign;
  }

  var norm = 0.0;
  for (final x in vec) {
    norm += x * x;
  }
  if (norm > 0) {
    final inv = 1 / sqrt(norm);
    for (var i = 0; i < vec.length; i++) {
      vec[i] *= inv;
    }
  }
  return List<double>.from(vec);
}

/// Unchecked 64-bit unsigned multiply — Dart int wraps on overflow on
/// the VM, so the low 64 bits match what Kotlin / Swift compute.
int _mulFnv64(int a, int b) {
  // On the Dart VM both operands are 64-bit. Java's * operator also
  // wraps on overflow so the result matches Kotlin's ULong math.
  return (a * b) & 0xFFFFFFFFFFFFFFFF;
}
