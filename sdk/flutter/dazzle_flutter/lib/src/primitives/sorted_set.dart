// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import '../ffi/bindings.dart';
import '../ffi/command.dart';

class ScoredMember {
  final String member;
  final double score;
  const ScoredMember(this.member, this.score);

  @override
  String toString() => 'ScoredMember($member @ $score)';
}

class SortedSetKey {
  SortedSetKey(this.key);
  final String key;

  bool add({required double score, required String member}) {
    final r = dazzleCommand(['ZADD', key, score.toString(), member]);
    return (r.asLongOrNull ?? 0) == 1;
  }

  /// Bulk ZADD. Returns the count of *new* members inserted.
  int addAll(Map<String, double> members) {
    if (members.isEmpty) return 0;
    final args = ['ZADD', key];
    members.forEach((m, s) => args..add(s.toString())..add(m));
    return dazzleCommand(args).asLongOrNull ?? 0;
  }

  double? score(String member) {
    final r = dazzleCommand(['ZSCORE', key, member]);
    final s = r.asStringOrNull;
    return s == null ? null : double.tryParse(s);
  }

  /// ZRANGE BY RANK (inclusive).
  List<String> range(int start, int stop) {
    final r = dazzleCommand(['ZRANGE', key, '$start', '$stop']);
    return r.asBulkArrayOrNull?.whereType<String>().toList() ?? const [];
  }

  /// ZRANGEBYSCORE — RESP path. Prefer [rangeByScoreDirect] for hot
  /// retrieval; this one survives arbitrarily long members (the
  /// snapshot cache caps members at 128 bytes and then falls back here
  /// automatically, but you can call this directly if you know the
  /// keyspace pattern has large payloads — e.g. JSON blobs in the
  /// `dazzle-precompute` pattern).
  List<String> rangeByScore({required double min, required double max}) {
    final r = dazzleCommand([
      'ZRANGEBYSCORE', key,
      _fmtScore(min), _fmtScore(max),
    ]);
    return r.asBulkArrayOrNull?.whereType<String>().toList() ?? const [];
  }

  /// RESP-free ZRANGEBYSCORE. Falls back to [rangeByScore] on miss or
  /// when the entry is snapshot-poisoned (e.g. member > 128 B).
  List<String> rangeByScoreDirect({required double min, required double max,
      int maxMembers = 64}) {
    final bindings = DazzleBindings.load();
    final keyPtr = key.toNativeUtf8();
    final out = calloc<ffi.Pointer<Utf8>>(maxMembers);
    try {
      final n = bindings.snapZRangeByScore(keyPtr, min, max, out, maxMembers);
      if (n < 0) return rangeByScore(min: min, max: max);
      final result = <String>[];
      for (var i = 0; i < n; i++) {
        final p = out[i];
        if (p != ffi.nullptr) {
          result.add(p.toDartString());
          bindings.directFree(p);
        }
      }
      return result;
    } finally {
      calloc.free(out);
      calloc.free(keyPtr);
    }
  }

  int remove(Iterable<String> members) {
    if (members.isEmpty) return 0;
    return dazzleCommand(['ZREM', key, ...members]).asLongOrNull ?? 0;
  }

  int size() => dazzleCommand(['ZCARD', key]).asLongOrNull ?? 0;
  bool deleteKey() => (dazzleCommand(['DEL', key]).asLongOrNull ?? 0) > 0;

  // Valkey accepts integral scores without decimals; emit them cleanly.
  static String _fmtScore(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
