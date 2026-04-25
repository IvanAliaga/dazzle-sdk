// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { NativeModules } from 'react-native';
import { asLong, asBulkArray, dazzleCommand, jsiSnap } from '../ffi/command';

const { DazzleReactNative } = NativeModules;

export class SetKey {
  constructor(public readonly key: string) {}

  async add(members: string[]): Promise<number> {
    if (members.length === 0) return 0;
    const r = await dazzleCommand(['SADD', this.key, ...members]);
    return asLong(r) ?? 0;
  }

  async remove(members: string[]): Promise<number> {
    if (members.length === 0) return 0;
    const r = await dazzleCommand(['SREM', this.key, ...members]);
    return asLong(r) ?? 0;
  }

  async members(): Promise<string[]> {
    const r = await dazzleCommand(['SMEMBERS', this.key]);
    const arr = asBulkArray(r);
    return arr ? arr.filter((x): x is string => x !== null) : [];
  }

  async membersDirect(maxMembers = 64): Promise<string[]> {
    // JSI → sync bridge → async bridge → RESP fallback.
    const jsiArr = jsiSnap.sMembers(this.key, maxMembers);
    if (jsiArr !== undefined) return jsiArr ?? this.members();
    if (DazzleReactNative?.snapSMembersSync) {
      try {
        const arr = DazzleReactNative.snapSMembersSync(
            this.key, maxMembers) as string[] | null;
        return arr ?? this.members();
      } catch {
        return this.members();
      }
    }
    try {
      const arr: string[] | null =
          await DazzleReactNative.snapSMembers(this.key, maxMembers);
      return arr ?? this.members();
    } catch {
      return this.members();
    }
  }

  async isMember(member: string): Promise<boolean> {
    const r = await dazzleCommand(['SISMEMBER', this.key, member]);
    return (asLong(r) ?? 0) === 1;
  }

  async size(): Promise<number> {
    const r = await dazzleCommand(['SCARD', this.key]);
    return asLong(r) ?? 0;
  }
}
