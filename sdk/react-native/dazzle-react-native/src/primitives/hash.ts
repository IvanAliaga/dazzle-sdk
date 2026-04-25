// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { NativeModules } from 'react-native';
import { asLong, asBulkArray, dazzleCommand, jsiSnap } from '../ffi/command';

const { DazzleReactNative } = NativeModules;

/**
 * Valkey Hash — keyed map of field → string value. Mirrors Kotlin/
 * Swift/Dart `HashKey`. Async because the native bridge is async.
 */
export class HashKey {
  constructor(public readonly key: string) {}

  async set(field: string, value: string): Promise<boolean> {
    const r = await dazzleCommand(['HSET', this.key, field, value]);
    return (asLong(r) ?? 0) === 1;
  }

  async setAll(pairs: Record<string, string>): Promise<number> {
    const fields = Object.entries(pairs);
    if (fields.length === 0) return 0;
    const argv = ['HSET', this.key];
    for (const [f, v] of fields) { argv.push(f, v); }
    const r = await dazzleCommand(argv);
    return asLong(r) ?? 0;
  }

  async get(field: string): Promise<string | null> {
    const r = await dazzleCommand(['HGET', this.key, field]);
    return (r as any).value ?? null;
  }

  /** RESP HGETALL. Prefer `getAllDirect` for hot reads. */
  async getAll(): Promise<Record<string, string>> {
    const r = await dazzleCommand(['HGETALL', this.key]);
    const arr = asBulkArray(r);
    const out: Record<string, string> = {};
    if (!arr) return out;
    for (let i = 0; i + 1 < arr.length; i += 2) {
      const f = arr[i]; const v = arr[i + 1];
      if (f != null && v != null) out[f] = v;
    }
    return out;
  }

  /** RESP-free typed HGETALL via the snapshot cache. Picks the
   *  fastest available path:
   *    1. JSI HostObject  — ~1 µs
   *    2. Sync bridge     — ~15 µs
   *    3. Async bridge    — ~100 µs
   *    4. RESP HGETALL    — fallback when the entry is
   *                          snapshot-poisoned (member / value > cap)
   */
  async getAllDirect(): Promise<Record<string, string>> {
    // 1. JSI
    const jsiFields = jsiSnap.hgetAll(this.key);
    if (jsiFields !== undefined) {
      if (jsiFields === null) return this.getAll();
      return flatToRecord(jsiFields);
    }
    // 2. Sync bridge
    if (DazzleReactNative?.snapHGetAllSync) {
      try {
        const fields = DazzleReactNative.snapHGetAllSync(this.key) as
            string[] | null;
        if (!fields) return this.getAll();
        return flatToRecord(fields);
      } catch {
        return this.getAll();
      }
    }
    // 3. Async bridge
    try {
      const fields: string[] | null =
          await DazzleReactNative.snapHGetAll(this.key);
      if (!fields) return this.getAll();
      return flatToRecord(fields);
    } catch {
      return this.getAll();
    }
  }

  /** Synchronous sibling of [getAllDirect]. Returns null on
   *  snapshot miss. Throws only when no sync path is available
   *  (no JSI + no blocking bridge). */
  getAllDirectSync(): Record<string, string> | null {
    const jsiFields = jsiSnap.hgetAll(this.key);
    if (jsiFields !== undefined) {
      return jsiFields === null ? null : flatToRecord(jsiFields);
    }
    if (!DazzleReactNative?.snapHGetAllSync) {
      throw new Error('snapHGetAllSync not exposed by the native module');
    }
    const fields = DazzleReactNative.snapHGetAllSync(this.key) as string[] | null;
    return fields === null ? null : flatToRecord(fields);
  }

  async delete(fields: string[]): Promise<number> {
    if (fields.length === 0) return 0;
    const r = await dazzleCommand(['HDEL', this.key, ...fields]);
    return asLong(r) ?? 0;
  }

  async length(): Promise<number> {
    const r = await dazzleCommand(['HLEN', this.key]);
    return asLong(r) ?? 0;
  }

  async deleteKey(): Promise<boolean> {
    const r = await dazzleCommand(['DEL', this.key]);
    return (asLong(r) ?? 0) > 0;
  }
}

function flatToRecord(flat: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i + 1 < flat.length; i += 2) {
    out[flat[i]] = flat[i + 1];
  }
  return out;
}
