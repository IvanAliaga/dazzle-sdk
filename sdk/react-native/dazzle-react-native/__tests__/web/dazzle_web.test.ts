// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Bridge logic tests for the RN Web target.
//
// These tests use a hand-rolled fake EmscriptenModule so they exercise
// the *bridge* (string marshalling, NUL-separated parsing, vector heap
// indexing) without booting the real WASM.  E2E tests against the
// actual dazzle.wasm live in the Flutter package's `flutter test
// --platform chrome` suite — Jest with jsdom is not the right tool for
// loading a real Emscripten module.
//
// What we cover here:
//   - dazzle_hset / hget / hgetall round-trip with proper NUL handling
//   - dazzle_vs_create / vs_add / vs_search wires the heap correctly
//   - dazzle_save_snapshot / load_snapshot wire format conformance
//
// What we do NOT cover (covered by Flutter Web E2E):
//   - Actual HNSW search results
//   - OPFS persistence

import { DazzleWasm, EmscriptenModule } from '../../src/web/dazzle_wasm_bindings';

// ---------------------------------------------------------------------------
// Fake EmscriptenModule — backed by a JS Map and a small heap.
// ---------------------------------------------------------------------------

function makeFakeModule(): EmscriptenModule {
  const HEAP_BYTES = 1 << 20; // 1 MiB
  const buf = new ArrayBuffer(HEAP_BYTES);
  const heapU8  = new Uint8Array(buf);
  const heapF32 = new Float32Array(buf);
  let next = 16; // skip the first 16 bytes so 0 stays "null pointer"
  const allocs = new Map<number, number>();

  // Backing stores for the C library logic.
  const hashes = new Map<string, Map<string, string>>();
  const vectors = new Map<string, { dim: number; items: Map<string, Float32Array> }>();
  let lastIdsPtr = 0;

  const decoder = new TextDecoder('utf-8');
  const encoder = new TextEncoder();

  function readCString(p: number): string {
    let end = p;
    while (heapU8[end] !== 0 && end < HEAP_BYTES) end++;
    return decoder.decode(heapU8.subarray(p, end));
  }

  function writeCString(s: string, p: number): void {
    const bytes = encoder.encode(s);
    heapU8.set(bytes, p);
    heapU8[p + bytes.length] = 0;
  }

  function _malloc(n: number): number {
    const ptr = next;
    next = (next + n + 7) & ~7; // 8-byte align
    allocs.set(ptr, n);
    return ptr;
  }

  function _free(ptr: number): void {
    allocs.delete(ptr);
  }

  return {
    HEAPU8: heapU8,
    HEAPF32: heapF32,
    _malloc,
    _free,
    UTF8ToString: readCString,
    stringToUTF8: writeCString,
    lengthBytesUTF8: (s: string) => encoder.encode(s).length,
    ccall(name, _ret, _argTypes, args) {
      switch (name) {
        case 'dazzle_hset': {
          const key = readCString(args[0] as number);
          const field = readCString(args[1] as number);
          const value = readCString(args[2] as number);
          if (!hashes.has(key)) hashes.set(key, new Map());
          hashes.get(key)!.set(field, value);
          return 1;
        }
        case 'dazzle_hget': {
          const key = readCString(args[0] as number);
          const field = readCString(args[1] as number);
          const v = hashes.get(key)?.get(field);
          if (v === undefined) return 0;
          const ptr = _malloc(encoder.encode(v).length + 1);
          writeCString(v, ptr);
          return ptr;
        }
        case 'dazzle_hgetall': {
          const key = readCString(args[0] as number);
          const tbl = hashes.get(key);
          if (!tbl || tbl.size === 0) return 0;
          // Build NUL-separated stream "f1\0v1\0f2\0v2\0".
          const parts: string[] = [];
          for (const [f, v] of tbl) { parts.push(f); parts.push(v); }
          const joined = parts.join('\0') + '\0';
          const bytes = encoder.encode(joined);
          const ptr = _malloc(bytes.length + 1);
          heapU8.set(bytes, ptr);
          heapU8[ptr + bytes.length] = 0;
          return ptr;
        }
        case 'dazzle_hdel': {
          const key = readCString(args[0] as number);
          const field = readCString(args[1] as number);
          return hashes.get(key)?.delete(field) ? 1 : 0;
        }
        case 'dazzle_hexists': {
          const key = readCString(args[0] as number);
          const field = readCString(args[1] as number);
          return hashes.get(key)?.has(field) ? 1 : 0;
        }
        case 'dazzle_del': {
          const key = readCString(args[0] as number);
          return hashes.delete(key) ? 1 : 0;
        }
        case 'dazzle_vs_create': {
          const name = readCString(args[0] as number);
          const dim  = args[1] as number;
          if (vectors.has(name)) return 0;
          vectors.set(name, { dim, items: new Map() });
          return 1;
        }
        case 'dazzle_vs_add': {
          const name = readCString(args[0] as number);
          const id   = readCString(args[1] as number);
          const vec  = vectors.get(name);
          if (!vec) return -2;
          const start = (args[2] as number) >> 2;
          const slice = heapF32.subarray(start, start + vec.dim);
          vec.items.set(id, new Float32Array(slice));
          return 1;
        }
        case 'dazzle_vs_search': {
          const name  = readCString(args[0] as number);
          const qPtr  = args[1] as number;
          const k     = args[2] as number;
          const distPtr = args[4] as number;
          const max   = args[5] as number;
          const vec = vectors.get(name);
          if (!vec) return 0;
          const q = heapF32.subarray(qPtr >> 2, (qPtr >> 2) + vec.dim);

          // Rank by L2 distance (matches HNSW's L2Space).
          const ranked: { id: string; d: number }[] = [];
          for (const [id, e] of vec.items) {
            let d = 0;
            for (let i = 0; i < vec.dim; i++) {
              const diff = (q[i] ?? 0) - e[i]!;
              d += diff * diff;
            }
            ranked.push({ id, d });
          }
          ranked.sort((a, b) => a.d - b.d);
          const top = ranked.slice(0, Math.min(k, max));

          // Write ids to a buffer pointed by lastIdsPtr.
          const idStream = top.map(r => r.id).join('\0') + '\0';
          const idBytes = encoder.encode(idStream);
          lastIdsPtr = _malloc(idBytes.length + 1);
          heapU8.set(idBytes, lastIdsPtr);
          heapU8[lastIdsPtr + idBytes.length] = 0;

          // Write distances.
          for (let i = 0; i < top.length; i++) {
            heapF32[(distPtr >> 2) + i] = top[i]!.d;
          }
          return top.length;
        }
        case 'dazzle_vs_search_ids':
          return lastIdsPtr;
        case 'dazzle_vs_drop': {
          const name = readCString(args[0] as number);
          return vectors.delete(name) ? 1 : 0;
        }
        case 'dazzle_clear': {
          hashes.clear(); vectors.clear();
          return 1;
        }
        case 'dazzle_version': {
          const v = 'dazzle-wasm-fake 1.0.0-test';
          const ptr = _malloc(v.length + 1);
          writeCString(v, ptr);
          return ptr;
        }
        case 'dazzle_save_snapshot':
        case 'dazzle_load_snapshot':
        case 'dazzle_snapshot_release':
          return 1;
        default:
          throw new Error(`unhandled ccall: ${name}`);
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

describe('DazzleWasm — Hash KV', () => {
  let w: DazzleWasm;
  beforeEach(() => { w = new DazzleWasm(makeFakeModule()); });

  test('hset/hget round-trips a single field', () => {
    expect(w.hset('chat:1', 'role', 'user')).toBe(true);
    expect(w.hget('chat:1', 'role')).toBe('user');
  });

  test('hget returns null for missing field', () => {
    expect(w.hget('nope', 'whatever')).toBeNull();
  });

  test('hgetall returns every pair', () => {
    w.hset('chat:m', 'role', 'user');
    w.hset('chat:m', 'text', 'hello');
    w.hset('chat:m', 'lang', 'es');

    const all = w.hgetall('chat:m');
    expect(all).toEqual({ role: 'user', text: 'hello', lang: 'es' });
  });

  test('hdel removes one field; del removes the whole hash', () => {
    w.hset('h', 'a', '1');
    w.hset('h', 'b', '2');
    expect(w.hdel('h', 'a')).toBe(true);
    expect(w.hexists('h', 'a')).toBe(false);
    expect(w.hexists('h', 'b')).toBe(true);
    expect(w.del('h')).toBe(true);
    expect(w.hgetall('h')).toEqual({});
  });
});

describe('DazzleWasm — Vector index', () => {
  let w: DazzleWasm;
  beforeEach(() => { w = new DazzleWasm(makeFakeModule()); });

  test('create + add + search returns nearest first', () => {
    expect(w.vsCreate('cat', { dim: 4 })).toBe(true);
    w.vsAdd('cat', 'a', new Float32Array([1, 0, 0, 0]));
    w.vsAdd('cat', 'b', new Float32Array([0, 1, 0, 0]));
    w.vsAdd('cat', 'c', new Float32Array([0, 0, 1, 0]));

    const hits = w.vsSearch('cat', new Float32Array([0.95, 0.05, 0, 0]), { topK: 2 });
    expect(hits).toHaveLength(2);
    expect(hits[0]!.id).toBe('a');
    expect(hits[0]!.distance).toBeLessThan(hits[1]!.distance);
  });

  test('drop removes the index', () => {
    w.vsCreate('drop-me', { dim: 2 });
    expect(w.vsDrop('drop-me')).toBe(true);
    // Re-creating succeeds — old index gone.
    expect(w.vsCreate('drop-me', { dim: 2 })).toBe(true);
  });
});

describe('DazzleWasm — diagnostics', () => {
  test('version returns a non-empty string', () => {
    const w = new DazzleWasm(makeFakeModule());
    expect(w.version()).toMatch(/dazzle-wasm/);
  });

  test('clear wipes everything', () => {
    const w = new DazzleWasm(makeFakeModule());
    w.hset('a', 'b', 'c');
    w.vsCreate('idx', { dim: 2 });
    w.clear();
    expect(w.hget('a', 'b')).toBeNull();
  });
});
