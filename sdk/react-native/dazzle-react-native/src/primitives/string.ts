// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { NativeModules } from 'react-native';
import { asLong, asString, dazzleCommand, jsiSnap } from '../ffi/command';

const { DazzleReactNative } = NativeModules;

export class StringKey {
  constructor(public readonly key: string) {}

  async set(value: string): Promise<boolean> {
    const r = await dazzleCommand(['SET', this.key, value]);
    return asString(r) === 'OK';
  }

  async get(): Promise<string | null> {
    const r = await dazzleCommand(['GET', this.key]);
    return asString(r);
  }

  async getDirect(): Promise<string | null> {
    // JSI → sync bridge → async bridge → RESP GET fallback.
    const jsiVal = jsiSnap.get(this.key);
    if (jsiVal !== undefined) return jsiVal ?? this.get();
    if (DazzleReactNative?.snapGetSync) {
      try {
        const s = DazzleReactNative.snapGetSync(this.key) as string | null;
        return s ?? this.get();
      } catch {
        return this.get();
      }
    }
    try {
      const s: string | null = await DazzleReactNative.snapGet(this.key);
      return s ?? this.get();
    } catch {
      return this.get();
    }
  }

  async increment(by = 1): Promise<number> {
    const r = await dazzleCommand(['INCRBY', this.key, String(by)]);
    return asLong(r) ?? 0;
  }

  async deleteKey(): Promise<boolean> {
    const r = await dazzleCommand(['DEL', this.key]);
    return (asLong(r) ?? 0) > 0;
  }
}
