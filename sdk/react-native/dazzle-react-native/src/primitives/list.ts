// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { asLong, asBulkArray, asString, dazzleCommand } from '../ffi/command';

export class ListKey {
  constructor(public readonly key: string) {}

  async push(...values: string[]): Promise<number> {
    if (values.length === 0) return 0;
    const r = await dazzleCommand(['RPUSH', this.key, ...values]);
    return asLong(r) ?? 0;
  }

  async pop(): Promise<string | null> {
    const r = await dazzleCommand(['LPOP', this.key]);
    return asString(r);
  }

  async range(start: number, stop: number): Promise<string[]> {
    const r = await dazzleCommand(
        ['LRANGE', this.key, String(start), String(stop)]);
    const arr = asBulkArray(r);
    return arr ? arr.filter((x): x is string => x !== null) : [];
  }

  async length(): Promise<number> {
    const r = await dazzleCommand(['LLEN', this.key]);
    return asLong(r) ?? 0;
  }
}
