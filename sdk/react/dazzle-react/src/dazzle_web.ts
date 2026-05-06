// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Public RN-Web API for Dazzle.  Mirrors `DazzleWeb` from the Flutter
// plugin so cross-platform code (e.g. an Expo app that targets both)
// can keep the same shape.

import { DazzleWasm, loadDazzleModule } from './dazzle_wasm_bindings';

export interface VectorSearchHit {
  id: string;
  distance: number;
}

let _wasm: DazzleWasm | null = null;
let _loading: Promise<DazzleWasm> | null = null;
let _opfsFile = 'dazzle-snapshot.bin';

export class DazzleWeb {
  private constructor() {}

  /** Load the WASM module and, if a snapshot exists in OPFS, restore it. */
  static async initialize(opts: { opfsFileName?: string } = {}): Promise<void> {
    _opfsFile = opts.opfsFileName ?? _opfsFile;
    if (_wasm) return;
    if (!_loading) {
      _loading = (async () => {
        const w = await loadDazzleModule();
        const snap = await readOpfsSnapshot(_opfsFile);
        if (snap && snap.length > 0) w.loadSnapshot(snap);
        _wasm = w;
        return w;
      })();
    }
    await _loading;
  }

  private static get w(): DazzleWasm {
    if (!_wasm) {
      throw new Error('DazzleWeb.initialize() must complete before calling primitives.');
    }
    return _wasm;
  }

  static hash(key: string): DazzleWebHash { return new DazzleWebHash(this.w, key); }
  static vectorIndex(name: string): DazzleWebVectorIndex { return new DazzleWebVectorIndex(this.w, name); }

  /** Snapshot current state to OPFS.  Call on app suspend, not per-write. */
  static async persist(): Promise<void> {
    const blob = this.w.saveSnapshot();
    if (blob.length === 0) return;
    await writeOpfsSnapshot(_opfsFile, blob);
  }

  /** Wipe in-memory state AND the OPFS snapshot. */
  static async clearAll(): Promise<void> {
    this.w.clear();
    await deleteOpfsSnapshot(_opfsFile);
  }

  static get version(): string { return this.w.version(); }

  /** Tests only. */
  static debugReset(): void {
    _wasm = null;
    _loading = null;
  }
}

export class DazzleWebHash {
  constructor(private readonly w: DazzleWasm, public readonly key: string) {}
  set(field: string, value: string): boolean { return this.w.hset(this.key, field, value); }
  get(field: string): string | null { return this.w.hget(this.key, field); }
  delete(field: string): boolean { return this.w.hdel(this.key, field); }
  exists(field: string): boolean { return this.w.hexists(this.key, field); }
  getAll(): Record<string, string> { return this.w.hgetall(this.key); }
  drop(): boolean { return this.w.del(this.key); }
}

export class DazzleWebVectorIndex {
  constructor(private readonly w: DazzleWasm, public readonly name: string) {}

  create(opts: { dim: number; M?: number; efConstruction?: number; initialCapacity?: number }): boolean {
    return this.w.vsCreate(this.name, opts);
  }

  add(id: string, embedding: Float32Array): boolean {
    return this.w.vsAdd(this.name, id, embedding);
  }

  addBatch(items: Record<string, Float32Array>): void {
    for (const [id, emb] of Object.entries(items)) this.w.vsAdd(this.name, id, emb);
  }

  search(query: Float32Array, opts: { topK?: number; ef?: number } = {}): VectorSearchHit[] {
    return this.w.vsSearch(this.name, query, opts);
  }

  drop(): boolean { return this.w.vsDrop(this.name); }
}

// ---------------------------------------------------------------------------
// OPFS persistence — same API surface in both Flutter and RN web bridges.
// ---------------------------------------------------------------------------

interface FileSystemDirectoryHandleX {
  getFileHandle(name: string, options?: { create?: boolean }): Promise<FileSystemFileHandleX>;
  removeEntry(name: string): Promise<void>;
}

interface FileSystemFileHandleX {
  getFile(): Promise<Blob>;
  createWritable(): Promise<FileSystemWritableFileStreamX>;
}

interface FileSystemWritableFileStreamX {
  write(data: Uint8Array | Blob | ArrayBuffer): Promise<void>;
  close(): Promise<void>;
}

interface StorageManagerX {
  getDirectory(): Promise<FileSystemDirectoryHandleX>;
}

async function opfsRoot(): Promise<FileSystemDirectoryHandleX> {
  const storage = (navigator as unknown as { storage: StorageManagerX }).storage;
  return storage.getDirectory();
}

async function readOpfsSnapshot(name: string): Promise<Uint8Array | null> {
  try {
    const root = await opfsRoot();
    const handle = await root.getFileHandle(name);
    const file = await handle.getFile();
    const ab = await file.arrayBuffer();
    return new Uint8Array(ab);
  } catch {
    return null;
  }
}

async function writeOpfsSnapshot(name: string, bytes: Uint8Array): Promise<void> {
  const root = await opfsRoot();
  const handle = await root.getFileHandle(name, { create: true });
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

async function deleteOpfsSnapshot(name: string): Promise<void> {
  try {
    const root = await opfsRoot();
    await root.removeEntry(name);
  } catch {
    // No-op if absent.
  }
}
