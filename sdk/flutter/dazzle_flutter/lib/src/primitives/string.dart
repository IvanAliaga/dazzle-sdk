// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert' show utf8;
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import '../ffi/bindings.dart';
import '../ffi/command.dart';

class StringKey {
  StringKey(this.key);
  final String key;

  /// SET key value [EX seconds].
  bool set(String value, {Duration? ttl}) {
    final args = ['SET', key, value];
    if (ttl != null) {
      args..add('EX')..add('${ttl.inSeconds}');
    }
    final r = dazzleCommand(args);
    return r.asStringOrNull == 'OK';
  }

  /// GET key. Prefer [getDirect] for hot reads.
  String? get() {
    final r = dazzleCommand(['GET', key]);
    return r.asStringOrNull;
  }

  /// RESP-free GET via snapshot cache. Falls back to [get] on miss.
  /// The snapshot buffer holds up to 256 bytes; values longer than
  /// that miss automatically (poisoned) and route to RESP.
  String? getDirect({int cap = 4096}) {
    final bindings = DazzleBindings.load();
    final keyPtr = key.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(cap);
    try {
      final n = bindings.snapGetString(keyPtr, buf, cap);
      if (n < 0) return get();
      final bytes = buf.asTypedList(n);
      return utf8.decode(List<int>.from(bytes), allowMalformed: true);
    } finally {
      calloc.free(buf);
      calloc.free(keyPtr);
    }
  }

  int? asInt() {
    final s = get();
    return s == null ? null : int.tryParse(s);
  }

  int incrBy(int by) =>
      dazzleCommand(['INCRBY', key, '$by']).asLongOrNull ?? 0;

  bool deleteKey() => (dazzleCommand(['DEL', key]).asLongOrNull ?? 0) > 0;
}
