// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import {
  DazzleServer, JsonSchema, Tool, ToolContext, jsonSchemaObject,
} from 'dazzle-react-native';
import { IotCorpus, IoTWindow } from './iotCorpus';

export interface TimeRange {
  min_from: number;
  min_to: number;
}

/**
 * Tool the LLM calls when the user asks about sensor data.
 *
 * Stays entirely on the snapshot-cache RESP-free path:
 *   1. `rangeByScoreDirect` → short IDs (JSI ~1 µs / sync bridge ~15 µs).
 *   2. per-ID `hgetAllDirect` → payload fields.
 *
 * Zero RESP round-trips in the hot path.
 */
export class RetrieveAnomaliesTool implements Tool<TimeRange, IoTWindow[]> {
  readonly name = 'retrieve_anomalies';
  readonly description =
    'Return the sensor windows overlapping [min_from..min_to] from ' +
    'the on-device Dazzle store. Each row includes averages, anomaly ' +
    'flag, and a one-line summary. Minutes are 0..2399.';

  readonly argsSchema: JsonSchema = jsonSchemaObject(
    { description: 'Time range (in minutes) to inspect.' },
    (b) => {
      b.property('min_from', { type: 'integer', required: true,
        description: 'Lower-bound minute, inclusive (0..2399).',
        minimum: 0, maximum: 2399 });
      b.property('min_to', { type: 'integer', required: true,
        description: 'Upper-bound minute, inclusive (0..2399).',
        minimum: 0, maximum: 2399 });
    },
  );

  argsFromJson(raw: string): TimeRange {
    const o = JSON.parse(raw);
    return { min_from: Number(o.min_from ?? 0), min_to: Number(o.min_to ?? 0) };
  }

  returnToJson(value: IoTWindow[]): string {
    return JSON.stringify(value);
  }

  async invoke(args: TimeRange, _ctx: ToolContext): Promise<IoTWindow[]> {
    const client = DazzleServer.shared.client();
    const sset = client.sortedSet(IotCorpus.sortedSetKey);

    // 1) Fast-path range read → short IDs via snapshot cache.
    const ids = await sset.rangeByScoreDirect(args.min_from, args.min_to);

    // 2) Hydrate each ID via `hgetAllDirect` — also snapshot HIT.
    const out: IoTWindow[] = [];
    for (const id of ids) {
      const fields = await client.hash(`${IotCorpus.hashPrefix}${id}`)
          .getAllDirect();
      const keys = Object.keys(fields);
      if (keys.length === 0) continue;
      out.push(IotCorpus.fromFields(fields as Record<string, string>));
    }
    return out;
  }
}
