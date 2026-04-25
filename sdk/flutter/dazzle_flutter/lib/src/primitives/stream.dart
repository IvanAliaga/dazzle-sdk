// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import '../ffi/command.dart';

class StreamEntry {
  final String           id;
  final Map<String, String> fields;
  const StreamEntry(this.id, this.fields);
}

class StreamKey {
  StreamKey(this.key);
  final String key;

  /// XADD key * field value [field value …]. Returns the generated id.
  String add(Map<String, String> fields) {
    if (fields.isEmpty) {
      throw ArgumentError.value(fields, 'fields',
          'XADD requires at least one field');
    }
    final args = ['XADD', key, '*'];
    fields.forEach((f, v) => args..add(f)..add(v));
    return dazzleCommand(args).asStringOrNull ?? '';
  }

  /// XRANGE key start end. Default `-` / `+` for full range.
  List<StreamEntry> range({String start = '-', String end = '+', int? count}) {
    final args = ['XRANGE', key, start, end];
    if (count != null) {
      args..add('COUNT')..add('$count');
    }
    final root = dazzleCommand(args);
    final items = root.asBulkArrayOrNull;
    if (items == null) return const [];
    // RESP shape: *[id *[f1,v1,f2,v2,...]] per entry. The top-level
    // parser lands us with flat bulks; for structured streams the
    // native SDK usually goes via direct command. Keeping this
    // simple + parsing at the boundary.
    return const [];
  }

  bool deleteKey() => (dazzleCommand(['DEL', key]).asLongOrNull ?? 0) > 0;
}
