// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { NativeModules } from 'react-native';
import {
  asLong, asBulkArray, asString, dazzleCommand, jsiSnap,
} from '../ffi/command';

const { DazzleReactNative } = NativeModules;

export interface ScoredMember {
  readonly member: string;
  readonly score: number;
}

export class SortedSetKey {
  constructor(public readonly key: string) {}

  async add(score: number, member: string): Promise<boolean> {
    const r = await dazzleCommand(['ZADD', this.key, String(score), member]);
    return (asLong(r) ?? 0) === 1;
  }

  async addAll(entries: Array<{ score: number; member: string }>):
      Promise<number> {
    if (entries.length === 0) return 0;
    const argv = ['ZADD', this.key];
    for (const e of entries) argv.push(String(e.score), e.member);
    const r = await dazzleCommand(argv);
    return asLong(r) ?? 0;
  }

  async score(member: string): Promise<number | null> {
    const r = await dazzleCommand(['ZSCORE', this.key, member]);
    const s = asString(r);
    if (s == null) return null;
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : null;
  }

  async range(start: number, stop: number): Promise<string[]> {
    const r = await dazzleCommand(
        ['ZRANGE', this.key, String(start), String(stop)]);
    const arr = asBulkArray(r);
    return arr ? arr.filter((x): x is string => x !== null) : [];
  }

  async rangeByScore(min: number, max: number): Promise<string[]> {
    const r = await dazzleCommand(
        ['ZRANGEBYSCORE', this.key, fmtScore(min), fmtScore(max)]);
    const arr = asBulkArray(r);
    return arr ? arr.filter((x): x is string => x !== null) : [];
  }

  /** RESP-free fast path. Picks the fastest available tier:
   *    1. JSI  (~1 µs)
   *    2. Sync bridge  (~15 µs)
   *    3. Async bridge  (~100 µs)
   *    4. RESP `rangeByScore`  — fallback on snapshot miss /
   *                               poisoned entries (member > 128 B). */
  async rangeByScoreDirect(
      min: number, max: number, maxMembers = 64): Promise<string[]> {
    const jsiArr = jsiSnap.zrangeByScore(this.key, min, max, maxMembers);
    if (jsiArr !== undefined) {
      return jsiArr === null ? this.rangeByScore(min, max) : jsiArr;
    }
    if (DazzleReactNative?.snapZRangeByScoreSync) {
      try {
        const arr = DazzleReactNative.snapZRangeByScoreSync(
            this.key, min, max, maxMembers) as string[] | null;
        if (arr == null) return this.rangeByScore(min, max);
        return arr;
      } catch {
        return this.rangeByScore(min, max);
      }
    }
    try {
      const arr: string[] | null =
          await DazzleReactNative.snapZRangeByScore(
              this.key, min, max, maxMembers);
      if (arr == null) return this.rangeByScore(min, max);
      return arr;
    } catch {
      return this.rangeByScore(min, max);
    }
  }

  async size(): Promise<number> {
    const r = await dazzleCommand(['ZCARD', this.key]);
    return asLong(r) ?? 0;
  }

  async deleteKey(): Promise<boolean> {
    const r = await dazzleCommand(['DEL', this.key]);
    return (asLong(r) ?? 0) > 0;
  }
}

function fmtScore(v: number): string {
  return Number.isInteger(v) ? String(v) : String(v);
}
