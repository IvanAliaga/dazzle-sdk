// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// DazzleServer facade — JS/TS mirror of the native `DazzleServer`
// object. Lifecycle goes through the NativeModule bridge; hot-path
// primitives go through `dazzleCommand` which is ALSO on the bridge
// today (see note in ffi/command.ts — future work: JSI zero-copy).

import { NativeModules } from 'react-native';
import { DazzleConfig, defaultConfig } from './config';
import { Dazzle } from './primitives/dazzle';

const { DazzleReactNative } = NativeModules;

export class DazzleServer {
  private static _instance: DazzleServer | null = null;
  private started = false;
  private readonly _client = new Dazzle();

  private constructor() {}

  static get shared(): DazzleServer {
    if (!this._instance) this._instance = new DazzleServer();
    return this._instance;
  }

  /** Boot the embedded Valkey server. Idempotent. */
  async start(config: DazzleConfig = defaultConfig): Promise<void> {
    if (this.started) return;
    await DazzleReactNative.start(serializeConfig(config));
    this.started = true;
  }

  async stop(): Promise<void> {
    if (!this.started) return;
    await DazzleReactNative.stop();
    this.started = false;
  }

  async isRunning(): Promise<boolean> {
    try {
      return !!(await DazzleReactNative.isRunning());
    } catch {
      return false;
    }
  }

  /** Wait until `start()` completes. */
  async waitForReady(timeoutMs = 5000): Promise<boolean> {
    if (this.started) return true;
    try {
      return !!(await DazzleReactNative.waitForReady(timeoutMs));
    } catch {
      return false;
    }
  }

  /** Typed primitive factory — mirrors native `server.client()`. */
  client(): Dazzle {
    return this._client;
  }
}

function serializeConfig(cfg: DazzleConfig): Record<string, unknown> {
  return {
    port: cfg.port ?? 0,
    maxMemory: cfg.maxMemory ?? '64mb',
    wipeOnStart: cfg.wipeOnStart ?? [],
    modules: cfg.modules ?? [],
    persistence: cfg.persistence ?? { kind: 'aof', fsync: 'everysec' },
    ...(cfg.dataDir ? { dataDir: cfg.dataDir } : {}),
  };
}
