// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { DazzleServer } from 'dazzle-react-native';
import rows from '../assets/iot_windows.json';

export interface IoTWindow {
  start_minute: number;
  end_minute: number;
  avg_temp_c: number;
  max_temp_c: number;
  min_temp_c: number;
  avg_humidity: number;
  anomaly_detected: boolean;
  anomaly_type: string;
  summary: string;
}

/**
 * Loads `iot_windows.json` into Dazzle using the production-grade
 * pattern:
 *
 *   ZSet  samples:iot:windows        score=start_minute, member="w-<n>"
 *   Hash  samples:iot:win:w-<n>      { start_minute, end_minute, ... }
 *
 * Short IDs in the ZSet keep `rangeByScoreDirect` on the snapshot-cache
 * RESP-free path (~1 µs via JSI / ~15 µs sync bridge / ~100 µs async).
 * Each hydrate is also Direct (`hgetAllDirect`). Zero RESP on the hot
 * path.
 */
export const IotCorpus = {
  sortedSetKey: 'samples:iot:windows',
  hashPrefix:   'samples:iot:win:',
  _loaded: false,

  async loadIntoDazzle(): Promise<void> {
    if (this._loaded) return;
    const client = DazzleServer.shared.client();
    const sset = client.sortedSet(this.sortedSetKey);

    // Fresh load each cold boot — ~30 rows is cheap.
    await sset.deleteKey();
    for (const row of rows as IoTWindow[]) {
      const id = IotCorpus.windowId(row.start_minute);
      const hash = client.hash(`${this.hashPrefix}${id}`);
      await hash.deleteKey();
      await sset.add(row.start_minute, id);
      await hash.setAll({
        start_minute:     String(row.start_minute),
        end_minute:       String(row.end_minute),
        avg_temp_c:       String(row.avg_temp_c),
        max_temp_c:       String(row.max_temp_c),
        min_temp_c:       String(row.min_temp_c),
        avg_humidity:     String(row.avg_humidity),
        anomaly_detected: String(row.anomaly_detected),
        anomaly_type:     row.anomaly_type,
        summary:          row.summary,
      });
    }
    this._loaded = true;
  },

  /** Short ID: "w-0195". ≤8 bytes, fits the 128-byte snapshot cap. */
  windowId(startMinute: number): string {
    return `w-${String(startMinute).padStart(4, '0')}`;
  },

  /** Rehydrate an IoTWindow from the flat Hash of strings returned by
   *  `hgetAllDirect`. */
  fromFields(f: Record<string, string>): IoTWindow {
    return {
      start_minute:     Number(f.start_minute),
      end_minute:       Number(f.end_minute),
      avg_temp_c:       Number(f.avg_temp_c),
      max_temp_c:       Number(f.max_temp_c),
      min_temp_c:       Number(f.min_temp_c),
      avg_humidity:     Number(f.avg_humidity),
      anomaly_detected: f.anomaly_detected === 'true',
      anomaly_type:     f.anomaly_type ?? 'none',
      summary:          f.summary ?? '',
    };
  },
};
