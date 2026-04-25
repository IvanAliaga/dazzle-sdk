// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../ffi/bindings.dart';
import '../ffi/command.dart';

/// Valkey Hash — keyed map of field → string value. Same semantics as
/// the Kotlin `HashKey` / Swift `HashKey`.
class HashKey {
  HashKey(this.key);
  final String key;

  /// HSET key field value. Returns `true` when a NEW field was added,
  /// `false` if the field existed (field overwritten).
  bool set(String field, String value) {
    final r = dazzleCommand(['HSET', key, field, value]);
    return (r.asLongOrNull ?? 0) == 1;
  }

  /// Bulk HSET. Returns the number of new (previously non-existent)
  /// fields created by the call.
  int setAll(Map<String, String> pairs) {
    if (pairs.isEmpty) return 0;
    final args = <String>['HSET', key];
    pairs.forEach((f, v) {
      args..add(f)..add(v);
    });
    return dazzleCommand(args).asLongOrNull ?? 0;
  }

  /// HGET key field.
  String? get(String field) {
    final r = dazzleCommand(['HGET', key, field]);
    return r.asStringOrNull;
  }

  /// HGETALL — RESP path. Prefer [getAllDirect] when the key was
  /// recently written — the snapshot-cache path is ~26× faster.
  Map<String, String> getAll() {
    final r = dazzleCommand(['HGETALL', key]).asBulkArrayOrNull;
    if (r == null) return const {};
    final out = <String, String>{};
    for (var i = 0; i + 1 < r.length; i += 2) {
      final f = r[i];
      final v = r[i + 1];
      if (f != null && v != null) out[f] = v;
    }
    return out;
  }

  /// RESP-free typed HGETALL. On miss (key not in snapshot cache, or
  /// poisoned via long-member overflow) falls back to [getAll].
  ///
  /// This is the path the native Kotlin / Swift SDKs use for
  /// `ContextStore.get()` — ~30 µs on A14, ~150 µs on mid-range
  /// Android.
  Map<String, String> getAllDirect({int maxPairs = 64}) {
    final bindings = DazzleBindings.load();
    final keyPtr = key.toNativeUtf8();
    final fields = calloc<ffi.Pointer<Utf8>>(maxPairs);
    final values = calloc<ffi.Pointer<Utf8>>(maxPairs);
    try {
      final n =
          bindings.snapHGetAll(keyPtr, fields, values, maxPairs);
      if (n < 0) {
        // Snapshot miss — fall back to RESP HGETALL.
        return getAll();
      }
      final out = <String, String>{};
      for (var i = 0; i < n; i++) {
        final f = fields[i];
        final v = values[i];
        if (f != ffi.nullptr && v != ffi.nullptr) {
          out[f.toDartString()] = v.toDartString();
        }
        if (f != ffi.nullptr) bindings.directFree(f);
        if (v != ffi.nullptr) bindings.directFree(v);
      }
      return out;
    } finally {
      calloc.free(fields);
      calloc.free(values);
      calloc.free(keyPtr);
    }
  }

  /// HDEL key field1 [field2 …]. Returns the number of fields removed.
  int delete(Iterable<String> fields) {
    final args = ['HDEL', key, ...fields];
    return dazzleCommand(args).asLongOrNull ?? 0;
  }

  /// HEXISTS key field.
  bool exists(String field) {
    final r = dazzleCommand(['HEXISTS', key, field]);
    return (r.asLongOrNull ?? 0) == 1;
  }

  /// HLEN key.
  int length() {
    final r = dazzleCommand(['HLEN', key]);
    return r.asLongOrNull ?? 0;
  }

  /// DEL key. `true` if the key was deleted.
  bool deleteKey() {
    final r = dazzleCommand(['DEL', key]);
    return (r.asLongOrNull ?? 0) > 0;
  }
}
