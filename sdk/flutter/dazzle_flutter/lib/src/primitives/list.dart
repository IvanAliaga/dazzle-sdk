// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import '../ffi/command.dart';

class ListKey {
  ListKey(this.key);
  final String key;

  int push(Iterable<String> values, {bool atHead = false}) {
    if (values.isEmpty) return 0;
    final cmd = atHead ? 'LPUSH' : 'RPUSH';
    return dazzleCommand([cmd, key, ...values]).asLongOrNull ?? 0;
  }

  String? pop({bool atHead = true}) {
    final cmd = atHead ? 'LPOP' : 'RPOP';
    return dazzleCommand([cmd, key]).asStringOrNull;
  }

  int size() => dazzleCommand(['LLEN', key]).asLongOrNull ?? 0;

  List<String> range(int start, int stop) {
    final r = dazzleCommand(['LRANGE', key, '$start', '$stop']);
    return r.asBulkArrayOrNull?.whereType<String>().toList() ?? const [];
  }

  bool deleteKey() => (dazzleCommand(['DEL', key]).asLongOrNull ?? 0) > 0;
}
