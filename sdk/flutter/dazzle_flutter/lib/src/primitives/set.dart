// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import '../ffi/bindings.dart';
import '../ffi/command.dart';

class SetKey {
  SetKey(this.key);
  final String key;

  int add(Iterable<String> members) {
    if (members.isEmpty) return 0;
    return dazzleCommand(['SADD', key, ...members]).asLongOrNull ?? 0;
  }

  int remove(Iterable<String> members) {
    if (members.isEmpty) return 0;
    return dazzleCommand(['SREM', key, ...members]).asLongOrNull ?? 0;
  }

  bool contains(String member) {
    final r = dazzleCommand(['SISMEMBER', key, member]);
    return (r.asLongOrNull ?? 0) == 1;
  }

  Set<String> members() {
    final r = dazzleCommand(['SMEMBERS', key]).asBulkArrayOrNull;
    return r?.whereType<String>().toSet() ?? const <String>{};
  }

  /// RESP-free SMEMBERS via snapshot cache. Falls back to [members] on miss.
  Set<String> membersDirect({int maxMembers = 64}) {
    final bindings = DazzleBindings.load();
    final keyPtr = key.toNativeUtf8();
    final out = calloc<ffi.Pointer<Utf8>>(maxMembers);
    try {
      final n = bindings.snapSMembers(keyPtr, out, maxMembers);
      if (n < 0) return members();
      final result = <String>{};
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

  int size() => dazzleCommand(['SCARD', key]).asLongOrNull ?? 0;
  bool deleteKey() => (dazzleCommand(['DEL', key]).asLongOrNull ?? 0) > 0;
}
