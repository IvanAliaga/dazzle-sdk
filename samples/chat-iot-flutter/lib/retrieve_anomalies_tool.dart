// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:dazzle_flutter/dazzle_flutter.dart';

import 'iot_corpus.dart';

/// Tool the LLM calls when the user asks about sensor data.
///
/// Wire-format (OpenAI-compatible):
/// ```
/// retrieve_anomalies(min_from: integer, min_to: integer)
///   → [{start_minute, end_minute, avg_temp_c, max_temp_c, avg_humidity,
///       anomaly_detected, anomaly_type, summary}]
/// ```
///
/// Stays entirely on the snapshot-cache RESP-free path:
///   1. `sset.rangeByScoreDirect` → short IDs (snapshot HIT).
///   2. per-ID `hash.getAllDirect` → payload fields (snapshot HIT).
///
/// Zero RESP in the hot path.
class RetrieveAnomaliesTool extends Tool<TimeRange, List<Map<String, dynamic>>> {
  @override
  String get name => 'retrieve_anomalies';

  @override
  String get description =>
      'Return the sensor windows overlapping [min_from..min_to] from '
      'the on-device Dazzle store. Each row includes averages, anomaly '
      'flag, and a one-line summary. Minutes are 0..2399.';

  @override
  JsonSchema get argsSchema => jsonSchemaObject(
        description: 'Time range (in minutes) to inspect.',
        build: (b) {
          b.property('min_from',
              type: 'integer',
              description: 'Lower-bound minute, inclusive (0..2399).',
              required: true,
              minimum: 0,
              maximum: 2399);
          b.property('min_to',
              type: 'integer',
              description: 'Upper-bound minute, inclusive (0..2399).',
              required: true,
              minimum: 0,
              maximum: 2399);
        },
      );

  @override
  TimeRange argsFromJson(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return TimeRange(
      minFrom: (m['min_from'] as num).toInt(),
      minTo:   (m['min_to']   as num).toInt(),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> invoke(
      TimeRange args, ToolContext ctx) async {
    final client = DazzleServer.shared.client();
    final sset = client.sortedSet(IotCorpus.sortedSetKey);

    // 1) Fast-path range read → short IDs via snapshot cache.
    final ids = sset.rangeByScoreDirect(
      min: args.minFrom.toDouble(),
      max: args.minTo.toDouble(),
    );

    // 2) Hydrate each ID via `hgetAllDirect` — also snapshot HIT.
    final out = <Map<String, dynamic>>[];
    for (final id in ids) {
      final fields = client.hash('${IotCorpus.hashPrefix}$id').getAllDirect();
      if (fields.isEmpty) continue;
      out.add(IoTWindow.fromFields(fields).toJson());
    }
    return out;
  }

  @override
  String returnToJson(List<Map<String, dynamic>> value) => jsonEncode(value);
}

/// Arguments the LLM sends when it calls `retrieve_anomalies`.
class TimeRange {
  const TimeRange({required this.minFrom, required this.minTo});
  final int minFrom;
  final int minTo;
}
