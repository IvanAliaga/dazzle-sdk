// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { asString, dazzleCommand, RespArray, RespBulk, RespValue }
    from '../ffi/command';

export interface StreamEntry {
  readonly id: string;
  readonly fields: Record<string, string>;
}

export class StreamKey {
  constructor(public readonly key: string) {}

  async add(fields: Record<string, string>, id = '*'): Promise<string | null> {
    const argv = ['XADD', this.key, id];
    for (const [k, v] of Object.entries(fields)) argv.push(k, v);
    const r = await dazzleCommand(argv);
    return asString(r);
  }

  async range(start = '-', end = '+'): Promise<StreamEntry[]> {
    const r = await dazzleCommand(['XRANGE', this.key, start, end]);
    return decodeEntries(r);
  }
}

function decodeEntries(v: RespValue): StreamEntry[] {
  if (!(v instanceof RespArray)) return [];
  const out: StreamEntry[] = [];
  for (const e of v.items) {
    if (!(e instanceof RespArray) || e.items.length < 2) continue;
    const idVal = e.items[0];
    const kvVal = e.items[1];
    if (!(idVal instanceof RespBulk) || !(kvVal instanceof RespArray)) continue;
    const fields: Record<string, string> = {};
    for (let i = 0; i + 1 < kvVal.items.length; i += 2) {
      const k = kvVal.items[i]; const val = kvVal.items[i + 1];
      if (k instanceof RespBulk && val instanceof RespBulk) {
        fields[k.value] = val.value;
      }
    }
    out.push({ id: idVal.value, fields });
  }
  return out;
}
