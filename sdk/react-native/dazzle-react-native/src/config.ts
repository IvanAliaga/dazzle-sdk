// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// DazzleConfig — mirrors Kotlin/Swift/Dart types. Serialises to a
// plain object the NativeModule bridge hands to DazzleServer.

export type AppendFsync = 'always' | 'everysec' | 'no';
export type WipeTarget = 'aof' | 'rdb';
export type DazzleModule = 'vectorSearch';

export type DazzlePersistence =
  | { kind: 'none' }
  | { kind: 'aof'; fsync: AppendFsync }
  | { kind: 'rdb'; saves?: [number, number][] };

export interface DazzleConfig {
  port?: number;
  maxMemory?: string;
  persistence?: DazzlePersistence;
  wipeOnStart?: WipeTarget[];
  modules?: DazzleModule[];
  dataDir?: string;
}

export const defaultConfig: DazzleConfig = {
  port: 0,
  maxMemory: '64mb',
  persistence: { kind: 'aof', fsync: 'everysec' },
  wipeOnStart: [],
  modules: [],
};
