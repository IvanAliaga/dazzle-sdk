// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Loads `assets/iot_windows.json` into Dazzle using the
/// **production-grade** pattern the paper benchmarks:
///
/// ```
/// ZSet  samples:iot:windows           score=start_minute, member="w-<n>"
/// Hash  samples:iot:win:w-<n>         { start_minute, end_minute, ... }
/// ```
///
/// The ZSet holds short IDs (≤8 bytes) so every `rangeByScoreDirect`
/// call stays on the snapshot-cache RESP-free path (~2 µs / HIT).
/// Each hydrate is also Direct (`hgetAllDirect`). Zero RESP on the
/// hot path.
class IotCorpus {
  static const String sortedSetKey = 'samples:iot:windows';
  static const String hashPrefix   = 'samples:iot:win:';
  static bool _loaded = false;

  static Future<void> loadIntoDazzle() async {
    if (_loaded) return;
    final raw = await rootBundle.loadString('assets/iot_windows.json');
    final rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();

    final client = DazzleServer.shared.client();
    final sset = client.sortedSet(sortedSetKey);

    // Fresh load every install — 30 rows is cheap.
    sset.deleteKey();
    for (final row in rows) {
      final win = IoTWindow.fromJson(row);
      final id = windowId(win.startMinute);
      final hash = client.hash('$hashPrefix$id');
      // Wipe any stale fields for this ID so the fresh write is clean.
      hash.deleteKey();
      sset.add(score: win.startMinute.toDouble(), member: id);
      hash.setAll({
        'start_minute':     win.startMinute.toString(),
        'end_minute':       win.endMinute.toString(),
        'avg_temp_c':       win.avgTempC.toString(),
        'max_temp_c':       win.maxTempC.toString(),
        'min_temp_c':       win.minTempC.toString(),
        'avg_humidity':     win.avgHumidity.toString(),
        'anomaly_detected': win.anomalyDetected.toString(),
        'anomaly_type':     win.anomalyType,
        'summary':          win.summary,
      });
    }
    _loaded = true;
  }

  /// Short ID: "w-0195". ≤8 bytes, fits the 128-byte snapshot cap.
  static String windowId(int startMinute) =>
      'w-${startMinute.toString().padLeft(4, '0')}';
}

class IoTWindow {
  const IoTWindow({
    required this.startMinute,
    required this.endMinute,
    required this.avgTempC,
    required this.maxTempC,
    required this.minTempC,
    required this.avgHumidity,
    required this.anomalyDetected,
    required this.anomalyType,
    required this.summary,
  });

  final int    startMinute;
  final int    endMinute;
  final double avgTempC;
  final double maxTempC;
  final double minTempC;
  final double avgHumidity;
  final bool   anomalyDetected;
  final String anomalyType;
  final String summary;

  factory IoTWindow.fromJson(Map<String, dynamic> j) => IoTWindow(
        startMinute:     (j['start_minute']     as num).toInt(),
        endMinute:       (j['end_minute']       as num).toInt(),
        avgTempC:        (j['avg_temp_c']       as num).toDouble(),
        maxTempC:        (j['max_temp_c']       as num).toDouble(),
        minTempC:        (j['min_temp_c']       as num).toDouble(),
        avgHumidity:     (j['avg_humidity']     as num).toDouble(),
        anomalyDetected:  j['anomaly_detected'] as bool,
        anomalyType:     (j['anomaly_type']     as String?) ?? 'none',
        summary:         (j['summary']          as String?) ?? '',
      );

  /// Rehydrate from the flat Hash of strings that `hgetAllDirect`
  /// returns.
  factory IoTWindow.fromFields(Map<String, String> f) => IoTWindow(
        startMinute:     int.parse(f['start_minute'] ?? '0'),
        endMinute:       int.parse(f['end_minute']   ?? '0'),
        avgTempC:        double.parse(f['avg_temp_c']   ?? '0'),
        maxTempC:        double.parse(f['max_temp_c']   ?? '0'),
        minTempC:        double.parse(f['min_temp_c']   ?? '0'),
        avgHumidity:     double.parse(f['avg_humidity'] ?? '0'),
        anomalyDetected: (f['anomaly_detected'] ?? 'false') == 'true',
        anomalyType:     f['anomaly_type'] ?? 'none',
        summary:         f['summary']      ?? '',
      );

  Map<String, dynamic> toJson() => {
        'start_minute':     startMinute,
        'end_minute':       endMinute,
        'avg_temp_c':       avgTempC,
        'max_temp_c':       maxTempC,
        'min_temp_c':       minTempC,
        'avg_humidity':     avgHumidity,
        'anomaly_detected': anomalyDetected,
        'anomaly_type':     anomalyType,
        'summary':          summary,
      };
}
