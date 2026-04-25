// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Typed wrapper around the dazzle-search HNSW module. Mirrors
// `VectorIndex.kt` / `.swift` / `.dart`. The direct fast-path
// (`addBatchDirect`, `searchDirect`) is bridged via the NativeModule
// until we upgrade to JSI — see comment in ffi/command.ts.

import { NativeModules } from 'react-native';
import { dazzleCommand, RespError } from '../ffi/command';

const { DazzleReactNative } = NativeModules;

export type VectorAlgorithm =
  | 'flat' | 'hnsw' | 'hnswSq8' | 'hnswSq8Rerank' | 'hnswF16';
export type VectorMetric = 'cosine' | 'l2' | 'ip';

export interface VectorSearchResult {
  readonly id: string;
  readonly distance: number;
}

export interface VectorIndexOptions {
  name: string;
  hashPrefix: string;
  vectorField?: string;
  dim: number;
  algorithm?: VectorAlgorithm;
  metric?: VectorMetric;
  m?: number;
  efConstruction?: number;
  initialCapacity?: number;
}

export class VectorIndex {
  private constructor(
      readonly name: string,
      readonly hashPrefix: string,
      readonly vectorField: string,
      readonly dim: number,
      readonly algorithm: VectorAlgorithm,
      readonly metric: VectorMetric,
      readonly m: number,
      readonly efConstruction: number) {}

  static async create(opts: VectorIndexOptions): Promise<VectorIndex> {
    const {
      name, hashPrefix,
      vectorField = 'embedding',
      dim,
      algorithm = 'hnsw',
      metric = 'cosine',
      m = 0,
      efConstruction = 0,
      initialCapacity = 0,
    } = opts;

    const idx = new VectorIndex(
        name, hashPrefix, vectorField, dim, algorithm, metric,
        m > 0 ? m : 32, efConstruction > 0 ? efConstruction : 400);

    await idx.createOnServer(initialCapacity);
    return idx;
  }

  private async createOnServer(initialCapacity: number): Promise<void> {
    if (this.algorithm === 'hnswSq8' ||
        this.algorithm === 'hnswSq8Rerank' ||
        this.algorithm === 'hnswF16') {
      if (this.metric !== 'cosine') {
        throw new Error(
            `${this.algorithm} only supports metric "cosine" — got ${this.metric}`);
      }
      await DazzleReactNative.vsCreate({
        name: this.name,
        algorithm: this.algorithm,
        dim: this.dim,
        m: this.m,
        ef: this.efConstruction,
        initialCapacity,
        rerank: this.algorithm === 'hnswSq8Rerank',
      });
      return;
    }
    // flat / hnsw via FT.CREATE (RESP).
    const algoStr = this.algorithm === 'flat' ? 'FLAT' : 'HNSW';
    const metricStr =
        this.metric === 'cosine' ? 'COSINE' :
        this.metric === 'l2'     ? 'L2'     : 'IP';
    const argv = [
      'FT.CREATE', this.name,
      'ON', 'HASH',
      'PREFIX', '1', this.hashPrefix,
      'SCHEMA',
      this.vectorField, 'VECTOR', algoStr, '6',
      'TYPE', 'FLOAT32',
      'DIM', String(this.dim),
      'DISTANCE_METRIC', metricStr,
    ];
    if (initialCapacity > 0) argv.push('INITIAL_CAP', String(initialCapacity));
    if (this.m > 0) argv.push('M', String(this.m));
    if (this.efConstruction > 0) argv.push('EF_CONSTRUCTION', String(this.efConstruction));
    const r = await dazzleCommand(argv);
    if (r instanceof RespError && !r.message.toLowerCase().includes('already')) {
      throw new Error(`FT.CREATE failed: ${r.message}`);
    }
  }

  async addDirect(id: string, vector: number[]): Promise<void> {
    if (vector.length !== this.dim) {
      throw new Error(`vector length ${vector.length} != dim ${this.dim}`);
    }
    await DazzleReactNative.vsAddDirect(this.name, id, vector);
  }

  async addBatchDirect(ids: string[], vectors: number[][]): Promise<void> {
    if (ids.length !== vectors.length) {
      throw new Error('ids.length != vectors.length');
    }
    if (ids.length === 0) return;
    // Flatten: one contiguous array of length n*dim.
    const flat = new Array<number>(ids.length * this.dim);
    for (let i = 0; i < ids.length; i++) {
      const v = vectors[i];
      if (v.length !== this.dim) {
        throw new Error(`vectors[${i}] length ${v.length} != dim ${this.dim}`);
      }
      for (let j = 0; j < this.dim; j++) flat[i * this.dim + j] = v[j];
    }
    await DazzleReactNative.vsAddBatchDirect(this.name, ids, flat, this.dim);
  }

  async searchDirect(
      query: number[],
      k = 10,
      efRuntime = 0): Promise<VectorSearchResult[]> {
    if (query.length !== this.dim) {
      throw new Error(`query length ${query.length} != dim ${this.dim}`);
    }
    const raw: Array<{ id: string; distance: number }> =
        await DazzleReactNative.vsSearchDirect(this.name, query, k, efRuntime);
    return raw.map((r) => ({ id: r.id, distance: r.distance }));
  }
}
