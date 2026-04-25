// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Typed Dazzle-backed store, mirroring `ContextStore<T>` in
// Kotlin/Swift. Persists any encodable value under a namespaced hash
// key ("<name>:<id>") using the snapshot-cache fast path.

import '../ffi/command.dart' show dazzleCommand, RespArray, RespBulk;
import '../primitives/dazzle.dart';

class ContextStore<T> {
  ContextStore({
    required this.name,
    required this.encode,
    required this.decode,
  });

  final String name;
  final Map<String, String> Function(T value) encode;
  final T? Function(Map<String, String> fields) decode;

  String _key(String id) => '$name:$id';

  /// Upsert a record. Overwrites field-by-field (hash merge semantics).
  void put(String id, T value) {
    final fields = Map<String, String>.from(encode(value))..['__id'] = id;
    Dazzle().hash(_key(id)).setAll(fields);
  }

  /// Fast-path read. Returns `null` if the hash doesn't exist or
  /// decoding fails.
  T? get(String id) {
    final fields = Dazzle().hash(_key(id)).getAllDirect();
    if (fields.isEmpty) return null;
    return decode(fields);
  }

  bool delete(String id) => Dazzle().hash(_key(id)).deleteKey();

  /// Iterate every record in the store. Uses cursor-based SCAN so big
  /// keyspaces don't block the main Isolate. Suitable for chat agents
  /// (<= a few hundred turns) or bulk restore.
  Iterable<(String, T)> iterate({int pageSize = 256}) sync* {
    var cursor = '0';
    while (true) {
      final reply = dazzleCommand(
          ['SCAN', cursor, 'MATCH', '$name:*', 'COUNT', '$pageSize']);
      if (reply is! RespArray || reply.items.length < 2) break;
      final nextCursor = switch (reply.items[0]) {
        RespBulk(:final value) => value,
        _ => '0',
      };
      final keys = switch (reply.items[1]) {
        RespArray(:final items) => items
            .whereType<RespBulk>()
            .map((e) => e.value)
            .toList(),
        _ => const <String>[],
      };
      for (final k in keys) {
        final id = k.substring(name.length + 1);
        final v = get(id);
        if (v != null) yield (id, v);
      }
      cursor = nextCursor;
      if (cursor == '0') break;
    }
  }
}
