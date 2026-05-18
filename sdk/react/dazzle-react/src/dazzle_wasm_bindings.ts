// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Low-level TypeScript bindings to the Emscripten-generated dazzle.wasm
// module.  Loaded once via `loadDazzleModule()`; the returned `DazzleWasm`
// instance owns the JS-side module and exposes typed wrappers around the
// `_dazzle_*` exports.

/**
 * Shape of the Emscripten module returned by `globalThis.dazzleModule()`.
 * We type it loosely because the codegen surface is large and stable.
 */
export interface EmscriptenModule {
  ccall(
    name: string,
    returnType: 'number' | 'string' | null,
    argTypes: string[],
    args: unknown[],
  ): unknown;

  _malloc(bytes: number): number;
  _free(ptr: number): void;

  UTF8ToString(ptr: number): string;
  stringToUTF8(str: string, ptr: number, maxBytes: number): void;
  lengthBytesUTF8(str: string): number;

  HEAPU8: Uint8Array;
  HEAPF32: Float32Array;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/consistent-type-definitions
  interface Window { dazzleModule?: () => Promise<EmscriptenModule>; }
  // eslint-disable-next-line no-var
  var dazzleModule: (() => Promise<EmscriptenModule>) | undefined;
}

export async function loadDazzleModule(timeoutMs = 10_000): Promise<DazzleWasm> {
  const g = globalThis as { dazzleModule?: () => Promise<EmscriptenModule> };
  const start = Date.now();
  while (typeof g.dazzleModule !== 'function') {
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        'dazzle.wasm loader not found on globalThis.dazzleModule. ' +
        'Add the loader <script> to your bundler entry HTML — see the ' +
        'dazzle-react-native/web README for the exact snippet.',
      );
    }
    await new Promise<void>((r) => setTimeout(r, 30));
  }
  const module = await g.dazzleModule!();
  return new DazzleWasm(module);
}

export class DazzleWasm {
  constructor(private readonly m: EmscriptenModule) {}

  // -------------- internals --------------

  private allocCString(s: string): number {
    const n = this.m.lengthBytesUTF8(s) + 1;
    const ptr = this.m._malloc(n);
    this.m.stringToUTF8(s, ptr, n);
    return ptr;
  }

  private callI(name: string, args: number[]): number {
    const argTypes = args.map(() => 'number');
    const ret = this.m.ccall(name, 'number', argTypes, args);
    return typeof ret === 'number' ? ret : 0;
  }

  /** Read a NUL-separated stream "a\0b\0c\0" as a JS array. */
  private readZeroSeparatedList(ptr: number): string[] {
    const heap = this.m.HEAPU8;
    let end = ptr;
    const cap = ptr + (1 << 20);
    while (end < cap && end < heap.length) {
      if (heap[end] === 0 && (end === ptr || heap[end - 1] === 0)) break;
      end++;
    }
    const decoder = new TextDecoder('utf-8');
    const raw = decoder.decode(heap.subarray(ptr, end));
    return raw.split('\0').filter((s) => s.length > 0);
  }

  // -------------- Hash KV --------------

  hset(key: string, field: string, value: string): boolean {
    const pK = this.allocCString(key);
    const pF = this.allocCString(field);
    const pV = this.allocCString(value);
    try {
      return this.callI('dazzle_hset', [pK, pF, pV]) > 0;
    } finally {
      this.m._free(pK); this.m._free(pF); this.m._free(pV);
    }
  }

  hget(key: string, field: string): string | null {
    const pK = this.allocCString(key);
    const pF = this.allocCString(field);
    try {
      const ret = this.callI('dazzle_hget', [pK, pF]);
      if (ret === 0) return null;
      return this.m.UTF8ToString(ret);
    } finally {
      this.m._free(pK); this.m._free(pF);
    }
  }

  hdel(key: string, field: string): boolean {
    const pK = this.allocCString(key);
    const pF = this.allocCString(field);
    try {
      return this.callI('dazzle_hdel', [pK, pF]) > 0;
    } finally {
      this.m._free(pK); this.m._free(pF);
    }
  }

  hexists(key: string, field: string): boolean {
    const pK = this.allocCString(key);
    const pF = this.allocCString(field);
    try {
      return this.callI('dazzle_hexists', [pK, pF]) === 1;
    } finally {
      this.m._free(pK); this.m._free(pF);
    }
  }

  hgetall(key: string): Record<string, string> {
    const pK = this.allocCString(key);
    try {
      const ret = this.callI('dazzle_hgetall', [pK]);
      if (ret === 0) return {};
      const parts = this.readZeroSeparatedList(ret);
      const out: Record<string, string> = {};
      for (let i = 0; i + 1 < parts.length; i += 2) {
        out[parts[i]!] = parts[i + 1]!;
      }
      return out;
    } finally {
      this.m._free(pK);
    }
  }

  del(key: string): boolean {
    const pK = this.allocCString(key);
    try {
      return this.callI('dazzle_del', [pK]) > 0;
    } finally {
      this.m._free(pK);
    }
  }

  // -------------- Vector index --------------

  vsCreate(name: string, opts: { dim: number; M?: number; efConstruction?: number; initialCapacity?: number }): boolean {
    const pN = this.allocCString(name);
    try {
      return this.callI('dazzle_vs_create', [
        pN,
        opts.dim,
        opts.M ?? 16,
        opts.efConstruction ?? 200,
        opts.initialCapacity ?? 1000,
      ]) > 0;
    } finally {
      this.m._free(pN);
    }
  }

  vsAdd(name: string, id: string, embedding: Float32Array): boolean {
    const pN = this.allocCString(name);
    const pI = this.allocCString(id);
    const pE = this.m._malloc(embedding.length * 4);
    try {
      this.m.HEAPF32.set(embedding, pE >> 2);
      return this.callI('dazzle_vs_add', [pN, pI, pE]) > 0;
    } finally {
      this.m._free(pN); this.m._free(pI); this.m._free(pE);
    }
  }

  vsSearch(
    name: string,
    query: Float32Array,
    opts: { topK?: number; ef?: number } = {},
  ): { id: string; distance: number }[] {
    const k  = opts.topK ?? 5;
    const ef = opts.ef ?? -1;
    const pN = this.allocCString(name);
    const pQ = this.m._malloc(query.length * 4);
    const pD = this.m._malloc(k * 4);
    try {
      this.m.HEAPF32.set(query, pQ >> 2);
      const n = this.callI('dazzle_vs_search', [pN, pQ, k, ef, pD, k]);
      if (n <= 0) return [];

      const idsPtr = this.callI('dazzle_vs_search_ids', []);
      const ids = this.readZeroSeparatedList(idsPtr);
      const distsView = this.m.HEAPF32.subarray(pD >> 2, (pD >> 2) + n);

      const out: { id: string; distance: number }[] = [];
      for (let i = 0; i < n && i < ids.length; i++) {
        out.push({ id: ids[i]!, distance: distsView[i]! });
      }
      return out;
    } finally {
      this.m._free(pN); this.m._free(pQ); this.m._free(pD);
    }
  }

  vsDrop(name: string): boolean {
    const pN = this.allocCString(name);
    try {
      return this.callI('dazzle_vs_drop', [pN]) > 0;
    } finally {
      this.m._free(pN);
    }
  }

  // -------------- Snapshot --------------

  saveSnapshot(): Uint8Array {
    const pBuf = this.m._malloc(4);
    const pLen = this.m._malloc(4);
    try {
      const ok = this.callI('dazzle_save_snapshot', [pBuf, pLen]);
      if (ok !== 1) return new Uint8Array(0);
      const heap = this.m.HEAPU8;
      const rd32 = (p: number): number =>
        (heap[p]!) | ((heap[p + 1]!) << 8) | ((heap[p + 2]!) << 16) | ((heap[p + 3]!) << 24);
      const addr = rd32(pBuf);
      const len  = rd32(pLen);
      const out = new Uint8Array(heap.subarray(addr, addr + len));
      this.callI('dazzle_snapshot_release', []);
      return out;
    } finally {
      this.m._free(pBuf); this.m._free(pLen);
    }
  }

  loadSnapshot(bytes: Uint8Array): boolean {
    const p = this.m._malloc(bytes.length);
    try {
      this.m.HEAPU8.set(bytes, p);
      return this.callI('dazzle_load_snapshot', [p, bytes.length]) === 1;
    } finally {
      this.m._free(p);
    }
  }

  clear(): void { this.callI('dazzle_clear', []); }

  version(): string {
    const ptr = this.callI('dazzle_version', []);
    return this.m.UTF8ToString(ptr);
  }
}
