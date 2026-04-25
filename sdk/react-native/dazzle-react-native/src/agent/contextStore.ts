// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Typed Dazzle-backed store, mirrors `ContextStore<T>` in
// Kotlin/Swift/Dart. Persists encodable values under a namespaced
// hash key (`<name>:<id>`).

import { dazzleCommand, RespArray, RespBulk } from '../ffi/command';
import { Dazzle } from '../primitives/dazzle';

export interface ContextStoreOptions<T> {
  name: string;
  encode: (value: T) => Record<string, string>;
  decode: (fields: Record<string, string>) => T | null;
}

export class ContextStore<T> {
  private readonly client = new Dazzle();

  constructor(private readonly opts: ContextStoreOptions<T>) {}

  private keyFor(id: string): string { return `${this.opts.name}:${id}`; }

  async put(id: string, value: T): Promise<void> {
    const fields = { ...this.opts.encode(value), __id: id };
    await this.client.hash(this.keyFor(id)).setAll(fields);
  }

  async get(id: string): Promise<T | null> {
    const fields = await this.client.hash(this.keyFor(id)).getAllDirect();
    if (!Object.keys(fields).length) return null;
    return this.opts.decode(fields);
  }

  async delete(id: string): Promise<boolean> {
    return this.client.hash(this.keyFor(id)).deleteKey();
  }

  /** Iterate every record in the store via SCAN. */
  async *iterate(pageSize = 256): AsyncIterable<[string, T]> {
    let cursor = '0';
    do {
      const r = await dazzleCommand(
          ['SCAN', cursor, 'MATCH', `${this.opts.name}:*`, 'COUNT', String(pageSize)]);
      if (!(r instanceof RespArray) || r.items.length < 2) break;
      const next = r.items[0] instanceof RespBulk ? r.items[0].value : '0';
      const keys: string[] = [];
      if (r.items[1] instanceof RespArray) {
        for (const e of r.items[1].items) {
          if (e instanceof RespBulk) keys.push(e.value);
        }
      }
      for (const k of keys) {
        const id = k.substring(this.opts.name.length + 1);
        const v = await this.get(id);
        if (v != null) yield [id, v];
      }
      cursor = next;
    } while (cursor !== '0');
  }
}
