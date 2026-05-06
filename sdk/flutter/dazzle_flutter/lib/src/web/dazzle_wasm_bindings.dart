// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Low-level dart:js_interop bindings to the Emscripten-generated
// `dazzle.wasm` module.
//
// Setup contract:
//
// The consuming Flutter Web app's `web/index.html` must include the WASM
// loader as an ES module *before* Flutter bootstraps. Example:
//
//     <script type="module">
//       import dz from "assets/packages/dazzle_flutter/web/native/dazzle.js";
//       globalThis.dazzleModule = dz;
//     </script>
//
// `loadDazzleModule()` then awaits `globalThis.dazzleModule(...)` which
// returns the typed Emscripten module.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// JS-interop view of the Emscripten module exports.
// ---------------------------------------------------------------------------

extension type _DazzleModule._(JSObject _) implements JSObject {
  external JSAny? ccall(JSString name, JSString? returnType,
      JSArray<JSString>? argTypes, JSArray<JSAny?>? args);

  external JSNumber _malloc(JSNumber bytes);
  external JSAny? _free(JSNumber ptr);
  external JSString UTF8ToString(JSNumber ptr);
  external JSAny? stringToUTF8(JSString str, JSNumber ptr, JSNumber maxBytes);
  external JSNumber lengthBytesUTF8(JSString str);

  external JSUint8Array get HEAPU8;
  external JSFloat32Array get HEAPF32;
}

/// Resolve the Emscripten module factory from `globalThis.dazzleModule` and
/// invoke it.  The factory returns `Promise<DazzleModule>`; we await it.
Future<DazzleWasm> loadDazzleModule({Duration timeout = const Duration(seconds: 10)}) async {
  // Poll until the host page has loaded the module loader script.
  final start = DateTime.now();
  while (!_factoryReady()) {
    if (DateTime.now().difference(start) > timeout) {
      throw StateError(
          'dazzle.wasm loader not found on globalThis.dazzleModule. '
          'Add the loader <script> to your web/index.html — see the '
          'dazzle_flutter README for the exact snippet.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  final factory = globalContext['dazzleModule'] as JSFunction;
  final modulePromise = factory.callAsFunction() as JSPromise;
  final module = (await modulePromise.toDart) as _DazzleModule;
  return DazzleWasm._(module);
}

bool _factoryReady() {
  final v = globalContext['dazzleModule'];
  return v != null && v.typeofEquals('function');
}

// ---------------------------------------------------------------------------
// DazzleWasm — typed wrapper around the C ABI.
// ---------------------------------------------------------------------------

class DazzleWasm {
  final _DazzleModule _m;
  DazzleWasm._(this._m);

  /// Allocate + write a UTF-8 string into the heap; caller frees the ptr.
  int _allocCString(String s) {
    final n = _m.lengthBytesUTF8(s.toJS).toDartInt + 1; // +NUL
    final ptr = _m._malloc(n.toJS).toDartInt;
    _m.stringToUTF8(s.toJS, ptr.toJS, n.toJS);
    return ptr;
  }

  // -------------- Hash KV --------------

  int hset(String key, String field, String value) {
    final pK = _allocCString(key);
    final pF = _allocCString(field);
    final pV = _allocCString(value);
    try {
      return _ccallI('dazzle_hset', [pK, pF, pV]);
    } finally {
      _m._free(pK.toJS); _m._free(pF.toJS); _m._free(pV.toJS);
    }
  }

  String? hget(String key, String field) {
    final pK = _allocCString(key);
    final pF = _allocCString(field);
    try {
      final ret = _ccallI('dazzle_hget', [pK, pF]);
      if (ret == 0) return null;
      return _m.UTF8ToString(ret.toJS).toDart;
    } finally {
      _m._free(pK.toJS); _m._free(pF.toJS);
    }
  }

  bool hdel(String key, String field) {
    final pK = _allocCString(key);
    final pF = _allocCString(field);
    try {
      return _ccallI('dazzle_hdel', [pK, pF]) > 0;
    } finally {
      _m._free(pK.toJS); _m._free(pF.toJS);
    }
  }

  bool hexists(String key, String field) {
    final pK = _allocCString(key);
    final pF = _allocCString(field);
    try {
      return _ccallI('dazzle_hexists', [pK, pF]) == 1;
    } finally {
      _m._free(pK.toJS); _m._free(pF.toJS);
    }
  }

  /// Returns `{field: value}` for every field on the hash. Empty if absent.
  Map<String, String> hgetall(String key) {
    final pK = _allocCString(key);
    try {
      final ret = _ccallI('dazzle_hgetall', [pK]);
      if (ret == 0) return const {};
      // The C side returns a NUL-separated stream "f1\0v1\0f2\0v2\0".
      // UTF8ToString stops at the first NUL, so we read raw heap bytes
      // up to the trailing double-NUL boundary instead.
      return _readZeroSeparatedPairs(ret);
    } finally {
      _m._free(pK.toJS);
    }
  }

  Map<String, String> _readZeroSeparatedPairs(int ptr) {
    final heap = _m.HEAPU8.toDart;
    // Find the end: two consecutive NULs OR a single NUL after a record.
    // Scan up to 1 MiB safety cap.
    int end = ptr;
    while (end < ptr + (1 << 20) && end < heap.length) {
      if (heap[end] == 0 && (end == ptr || heap[end - 1] == 0)) break;
      end++;
    }
    final bytes = heap.sublist(ptr, end);
    final raw = String.fromCharCodes(bytes);
    final parts = raw.split(String.fromCharCode(0))..removeWhere((s) => s.isEmpty);
    final out = <String, String>{};
    for (var i = 0; i + 1 < parts.length; i += 2) {
      out[parts[i]] = parts[i + 1];
    }
    return out;
  }

  bool del(String key) {
    final pK = _allocCString(key);
    try {
      return _ccallI('dazzle_del', [pK]) > 0;
    } finally {
      _m._free(pK.toJS);
    }
  }

  // -------------- Vector index --------------

  bool vsCreate(String name,
      {required int dim, int M = 16, int efConstruction = 200, int initialCapacity = 1000}) {
    final pN = _allocCString(name);
    try {
      return _ccallI('dazzle_vs_create', [pN, dim, M, efConstruction, initialCapacity]) > 0;
    } finally {
      _m._free(pN.toJS);
    }
  }

  bool vsAdd(String name, String id, Float32List embedding) {
    final pN = _allocCString(name);
    final pI = _allocCString(id);
    final pE = _m._malloc((embedding.length * 4).toJS).toDartInt;
    try {
      _m.HEAPF32.toDart.setRange(pE >> 2, (pE >> 2) + embedding.length, embedding);
      return _ccallI('dazzle_vs_add', [pN, pI, pE]) > 0;
    } finally {
      _m._free(pN.toJS); _m._free(pI.toJS); _m._free(pE.toJS);
    }
  }

  /// Top-K nearest neighbours.
  List<({String id, double distance})> vsSearch(
      String name, Float32List query, {int k = 5, int? ef}) {
    final pN = _allocCString(name);
    final pQ = _m._malloc((query.length * 4).toJS).toDartInt;
    final pD = _m._malloc((k * 4).toJS).toDartInt;
    try {
      _m.HEAPF32.toDart.setRange(pQ >> 2, (pQ >> 2) + query.length, query);
      final n = _ccallI('dazzle_vs_search', [pN, pQ, k, ef ?? -1, pD, k]);
      if (n <= 0) return const [];

      final idsPtr = _ccallI('dazzle_vs_search_ids', const []);
      final ids = _readZeroSeparatedList(idsPtr);
      final dists = _m.HEAPF32.toDart.sublist(pD >> 2, (pD >> 2) + n);

      return [
        for (var i = 0; i < n && i < ids.length; i++)
          (id: ids[i], distance: dists[i].toDouble())
      ];
    } finally {
      _m._free(pN.toJS); _m._free(pQ.toJS); _m._free(pD.toJS);
    }
  }

  List<String> _readZeroSeparatedList(int ptr) {
    final heap = _m.HEAPU8.toDart;
    int end = ptr;
    while (end < ptr + (1 << 20) && end < heap.length) {
      if (heap[end] == 0 && (end == ptr || heap[end - 1] == 0)) break;
      end++;
    }
    final raw = String.fromCharCodes(heap.sublist(ptr, end));
    return raw.split(String.fromCharCode(0))..removeWhere((s) => s.isEmpty);
  }

  bool vsDrop(String name) {
    final pN = _allocCString(name);
    try {
      return _ccallI('dazzle_vs_drop', [pN]) > 0;
    } finally {
      _m._free(pN.toJS);
    }
  }

  // -------------- Snapshot --------------

  Uint8List saveSnapshot() {
    final pBuf = _m._malloc(4.toJS).toDartInt;
    final pLen = _m._malloc(4.toJS).toDartInt;
    try {
      final ok = _ccallI('dazzle_save_snapshot', [pBuf, pLen]);
      if (ok != 1) return Uint8List(0);
      final heap = _m.HEAPU8.toDart;
      int rd32(int p) => heap[p] | (heap[p + 1] << 8) | (heap[p + 2] << 16) | (heap[p + 3] << 24);
      final addr = rd32(pBuf);
      final len  = rd32(pLen);
      final out = Uint8List.fromList(heap.sublist(addr, addr + len));
      _ccallI('dazzle_snapshot_release', const []);
      return out;
    } finally {
      _m._free(pBuf.toJS); _m._free(pLen.toJS);
    }
  }

  bool loadSnapshot(Uint8List bytes) {
    final p = _m._malloc(bytes.length.toJS).toDartInt;
    try {
      _m.HEAPU8.toDart.setRange(p, p + bytes.length, bytes);
      return _ccallI('dazzle_load_snapshot', [p, bytes.length]) == 1;
    } finally {
      _m._free(p.toJS);
    }
  }

  void clear() => _ccallI('dazzle_clear', const []);

  String version() {
    final ptr = _ccallI('dazzle_version', const []);
    return _m.UTF8ToString(ptr.toJS).toDart;
  }

  // -------------- Internals --------------

  int _ccallI(String name, List<int> args) {
    final argTypes = JSArray<JSString>.withLength(args.length);
    final argVals  = JSArray<JSAny?>.withLength(args.length);
    for (var i = 0; i < args.length; i++) {
      argTypes[i] = 'number'.toJS;
      argVals[i]  = args[i].toJS;
    }
    final ret = _m.ccall(name.toJS, 'number'.toJS, argTypes, argVals);
    if (ret == null) return 0;
    return (ret as JSNumber).toDartInt;
  }
}
