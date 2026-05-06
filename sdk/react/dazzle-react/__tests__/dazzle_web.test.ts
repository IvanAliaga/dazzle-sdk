// Bridge logic tests — same fake-EmscriptenModule strategy as the
// dazzle-react-native suite.  React-specific hook tests need a real
// browser to load the WASM, so they're not in this Jest run; that
// coverage is provided by the Flutter Web `flutter test --platform
// chrome` suite which exercises the same .wasm.

import { DazzleWasm, EmscriptenModule } from '../src/dazzle_wasm_bindings';

function makeFakeModule(): EmscriptenModule {
  const HEAP_BYTES = 1 << 20;
  const buf = new ArrayBuffer(HEAP_BYTES);
  const heapU8 = new Uint8Array(buf);
  const heapF32 = new Float32Array(buf);
  let next = 16;
  const allocs = new Map<number, number>();
  const hashes = new Map<string, Map<string, string>>();
  const vectors = new Map<string, { dim: number; items: Map<string, Float32Array> }>();
  let lastIdsPtr = 0;
  const decoder = new TextDecoder('utf-8');
  const encoder = new TextEncoder();

  const readCString = (p: number): string => {
    let end = p;
    while (heapU8[end] !== 0 && end < HEAP_BYTES) end++;
    return decoder.decode(heapU8.subarray(p, end));
  };
  const writeCString = (s: string, p: number): void => {
    const bytes = encoder.encode(s);
    heapU8.set(bytes, p);
    heapU8[p + bytes.length] = 0;
  };
  const _malloc = (n: number): number => { const ptr = next; next = (next + n + 7) & ~7; allocs.set(ptr, n); return ptr; };
  const _free = (ptr: number): void => { allocs.delete(ptr); };

  return {
    HEAPU8: heapU8, HEAPF32: heapF32, _malloc, _free,
    UTF8ToString: readCString, stringToUTF8: writeCString,
    lengthBytesUTF8: (s) => encoder.encode(s).length,
    ccall(name, _r, _t, args) {
      switch (name) {
        case 'dazzle_hset': {
          const k = readCString(args[0] as number); const f = readCString(args[1] as number); const v = readCString(args[2] as number);
          if (!hashes.has(k)) hashes.set(k, new Map());
          hashes.get(k)!.set(f, v);
          return 1;
        }
        case 'dazzle_hget': {
          const k = readCString(args[0] as number); const f = readCString(args[1] as number);
          const v = hashes.get(k)?.get(f);
          if (v === undefined) return 0;
          const ptr = _malloc(encoder.encode(v).length + 1);
          writeCString(v, ptr);
          return ptr;
        }
        case 'dazzle_hdel': return hashes.get(readCString(args[0] as number))?.delete(readCString(args[1] as number)) ? 1 : 0;
        case 'dazzle_hexists': return hashes.get(readCString(args[0] as number))?.has(readCString(args[1] as number)) ? 1 : 0;
        case 'dazzle_hgetall': {
          const tbl = hashes.get(readCString(args[0] as number));
          if (!tbl || tbl.size === 0) return 0;
          const parts: string[] = [];
          for (const [f, v] of tbl) { parts.push(f); parts.push(v); }
          const joined = parts.join('\0') + '\0';
          const bytes = encoder.encode(joined);
          const ptr = _malloc(bytes.length + 1);
          heapU8.set(bytes, ptr);
          heapU8[ptr + bytes.length] = 0;
          return ptr;
        }
        case 'dazzle_del': return hashes.delete(readCString(args[0] as number)) ? 1 : 0;
        case 'dazzle_vs_create': {
          const name = readCString(args[0] as number); const dim = args[1] as number;
          if (vectors.has(name)) return 0;
          vectors.set(name, { dim, items: new Map() });
          return 1;
        }
        case 'dazzle_vs_add': {
          const name = readCString(args[0] as number); const id = readCString(args[1] as number);
          const v = vectors.get(name); if (!v) return -2;
          const start = (args[2] as number) >> 2;
          v.items.set(id, new Float32Array(heapF32.subarray(start, start + v.dim)));
          return 1;
        }
        case 'dazzle_vs_search': {
          const v = vectors.get(readCString(args[0] as number)); if (!v) return 0;
          const qPtr = args[1] as number; const k = args[2] as number;
          const distPtr = args[4] as number; const max = args[5] as number;
          const q = heapF32.subarray(qPtr >> 2, (qPtr >> 2) + v.dim);
          const ranked: { id: string; d: number }[] = [];
          for (const [id, e] of v.items) {
            let d = 0; for (let i = 0; i < v.dim; i++) { const x = (q[i] ?? 0) - e[i]!; d += x * x; }
            ranked.push({ id, d });
          }
          ranked.sort((a, b) => a.d - b.d);
          const top = ranked.slice(0, Math.min(k, max));
          const idStream = top.map(r => r.id).join('\0') + '\0';
          const idBytes = encoder.encode(idStream);
          lastIdsPtr = _malloc(idBytes.length + 1);
          heapU8.set(idBytes, lastIdsPtr);
          heapU8[lastIdsPtr + idBytes.length] = 0;
          for (let i = 0; i < top.length; i++) heapF32[(distPtr >> 2) + i] = top[i]!.d;
          return top.length;
        }
        case 'dazzle_vs_search_ids': return lastIdsPtr;
        case 'dazzle_vs_drop': return vectors.delete(readCString(args[0] as number)) ? 1 : 0;
        case 'dazzle_clear': hashes.clear(); vectors.clear(); return 1;
        case 'dazzle_version': {
          const v = 'dazzle-wasm-fake 1.0.0-test';
          const ptr = _malloc(v.length + 1); writeCString(v, ptr); return ptr;
        }
        case 'dazzle_save_snapshot':
        case 'dazzle_load_snapshot':
        case 'dazzle_snapshot_release':
          return 1;
        default: throw new Error(`unhandled ccall: ${name}`);
      }
    },
  };
}

describe('dazzle-react bridge — Hash KV', () => {
  let w: DazzleWasm;
  beforeEach(() => { w = new DazzleWasm(makeFakeModule()); });

  test('hset/hget round-trip', () => {
    expect(w.hset('chat:1', 'role', 'user')).toBe(true);
    expect(w.hget('chat:1', 'role')).toBe('user');
  });

  test('hgetall returns every pair', () => {
    w.hset('h', 'a', '1'); w.hset('h', 'b', '2'); w.hset('h', 'c', '3');
    expect(w.hgetall('h')).toEqual({ a: '1', b: '2', c: '3' });
  });
});

describe('dazzle-react bridge — Vector', () => {
  let w: DazzleWasm;
  beforeEach(() => { w = new DazzleWasm(makeFakeModule()); });

  test('create + add + search ranks nearest first', () => {
    w.vsCreate('cat', { dim: 4 });
    w.vsAdd('cat', 'a', new Float32Array([1, 0, 0, 0]));
    w.vsAdd('cat', 'b', new Float32Array([0, 1, 0, 0]));
    const hits = w.vsSearch('cat', new Float32Array([0.95, 0.05, 0, 0]), { topK: 2 });
    expect(hits[0]!.id).toBe('a');
  });
});
