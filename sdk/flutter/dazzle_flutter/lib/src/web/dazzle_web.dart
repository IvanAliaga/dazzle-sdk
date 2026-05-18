// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Public Flutter Web API for Dazzle.
//
// MVP scope (Scope A): Hash KV + Vector index + OPFS persistence.
// Lists / Sets / SortedSets / Streams / on-device LLM clients are
// `UnimplementedError` on web in this beta — those primitives stay on
// the iOS / Android / Desktop targets.
//
// Usage:
//
// ```dart
// await DazzleWeb.initialize();          // loads the WASM module + restores OPFS snapshot
// final hash = DazzleWeb.hash('chat:1');
// hash.set('role', 'user');
// hash.set('text', 'hello');
//
// final vec = DazzleWeb.vectorIndex('catalog');
// vec.create(dim: 1536);
// vec.add('product-1', embedding);        // Float32List
// final hits = vec.search(query, topK: 5);
//
// await DazzleWeb.persist();              // writes a snapshot to OPFS
// ```

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'dazzle_wasm_bindings.dart';

/// Singleton entry point for the Dazzle WASM runtime.
///
/// One module per page session — concurrent calls to `initialize()` after
/// the first are coalesced and resolve to the same instance.
class DazzleWeb {
  DazzleWeb._();

  static DazzleWasm? _wasm;
  static Future<DazzleWasm>? _loading;
  static String _opfsFile = 'dazzle-snapshot.bin';

  /// Load the WASM module and, if a snapshot exists in OPFS, restore it.
  ///
  /// Pass [opfsFileName] if you need multiple isolated stores in the same
  /// origin (e.g. one per logged-in user).
  static Future<void> initialize({String opfsFileName = 'dazzle-snapshot.bin'}) async {
    _opfsFile = opfsFileName;
    if (_wasm != null) return;
    _loading ??= _doInit();
    await _loading!;
  }

  static Future<DazzleWasm> _doInit() async {
    final w = await loadDazzleModule();
    final snapshot = await _readOpfsSnapshot(_opfsFile);
    if (snapshot != null && snapshot.isNotEmpty) {
      w.loadSnapshot(snapshot);
    }
    _wasm = w;
    return w;
  }

  static DazzleWasm get _w {
    final w = _wasm;
    if (w == null) {
      throw StateError('DazzleWeb.initialize() must complete before calling primitives.');
    }
    return w;
  }

  /// Hash key handle.
  static DazzleWebHash hash(String key) => DazzleWebHash._(_w, key);

  /// Vector index handle.
  static DazzleWebVectorIndex vectorIndex(String name) => DazzleWebVectorIndex._(_w, name);

  /// Serialise the current state to OPFS.  Call this on app suspend or
  /// after batches of writes — fine-grained call-per-write is wasteful.
  static Future<void> persist() async {
    final blob = _w.saveSnapshot();
    if (blob.isEmpty) return;
    await _writeOpfsSnapshot(_opfsFile, blob);
  }

  /// Drop everything in memory AND the OPFS snapshot.  Useful for
  /// "Sign out" flows that shouldn't leak the previous session's data.
  static Future<void> clearAll() async {
    _w.clear();
    await _deleteOpfsSnapshot(_opfsFile);
  }

  /// Native runtime version string (e.g. `dazzle-wasm 1.0.0-beta.5`).
  static String get version => _w.version();

  // For tests only.
  static void debugReset() {
    _wasm = null;
    _loading = null;
  }
}

// ---------------------------------------------------------------------------
// Hash key API.
// ---------------------------------------------------------------------------

class DazzleWebHash {
  final DazzleWasm _w;
  final String key;
  DazzleWebHash._(this._w, this.key);

  void set(String field, String value) => _w.hset(key, field, value);
  String? get(String field) => _w.hget(key, field);
  bool delete(String field) => _w.hdel(key, field);
  bool exists(String field) => _w.hexists(key, field);
  Map<String, String> getAll() => _w.hgetall(key);
  bool drop() => _w.del(key);
}

// ---------------------------------------------------------------------------
// Vector index API.
// ---------------------------------------------------------------------------

class DazzleWebVectorIndex {
  final DazzleWasm _w;
  final String name;
  DazzleWebVectorIndex._(this._w, this.name);

  /// Create the underlying HNSW index.  Idempotent — second call is a no-op.
  bool create({required int dim, int M = 16, int efConstruction = 200, int initialCapacity = 1000}) {
    return _w.vsCreate(name,
        dim: dim, M: M, efConstruction: efConstruction, initialCapacity: initialCapacity);
  }

  bool add(String id, Float32List embedding) => _w.vsAdd(name, id, embedding);

  void addBatch(Map<String, Float32List> items) {
    for (final entry in items.entries) {
      _w.vsAdd(name, entry.key, entry.value);
    }
  }

  List<({String id, double distance})> search(Float32List query, {int topK = 5, int? ef}) {
    return _w.vsSearch(name, query, k: topK, ef: ef);
  }

  bool drop() => _w.vsDrop(name);
}

// ---------------------------------------------------------------------------
// OPFS persistence — Origin Private File System.
//
// Available in modern Chromium / Firefox / Safari (Safari 15.2+).  Quota
// is per-origin and persistent across reloads.  We keep a single binary
// snapshot file per logical store name.
// ---------------------------------------------------------------------------

extension type _StorageManager._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> getDirectory();
}

extension type _FileSystemDirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> getFileHandle(JSString name, [_GetFileHandleOptions options]);
  external JSPromise<JSAny?> removeEntry(JSString name);
}

@JS()
@anonymous
extension type _GetFileHandleOptions._(JSObject _) implements JSObject {
  external factory _GetFileHandleOptions({bool create});
}

extension type _FileSystemFileHandle._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> getFile();
  external JSPromise<JSAny?> createWritable();
}

extension type _FileSystemWritableFileStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny? data);
  external JSPromise<JSAny?> close();
}

extension type _BlobLike._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> arrayBuffer();
}

Future<Uint8List?> _readOpfsSnapshot(String fileName) async {
  try {
    final root = await _opfsRoot();
    final fileHandle = (await root
            .getFileHandle(fileName.toJS)
            .toDart) as _FileSystemFileHandle?;
    if (fileHandle == null) return null;
    final blob = (await fileHandle.getFile().toDart) as _BlobLike;
    final ab = (await blob.arrayBuffer().toDart) as JSArrayBuffer;
    return ab.toDart.asUint8List();
  } catch (_) {
    // Most likely "NotFoundError" — first run, no snapshot yet.
    return null;
  }
}

Future<void> _writeOpfsSnapshot(String fileName, Uint8List bytes) async {
  final root = await _opfsRoot();
  final handle = (await root
          .getFileHandle(fileName.toJS, _GetFileHandleOptions(create: true))
          .toDart) as _FileSystemFileHandle;
  final writable = (await handle.createWritable().toDart) as _FileSystemWritableFileStream;
  // FileSystemWritableFileStream.write accepts BufferSource directly —
  // pass the typed-array view rather than wrapping in a Blob.
  await writable.write(bytes.toJS).toDart;
  await writable.close().toDart;
}

Future<void> _deleteOpfsSnapshot(String fileName) async {
  try {
    final root = await _opfsRoot();
    await root.removeEntry(fileName.toJS).toDart;
  } catch (_) {
    // No-op if the snapshot didn't exist.
  }
}

Future<_FileSystemDirectoryHandle> _opfsRoot() async {
  final storage = web.window.navigator.storage as _StorageManager;
  return (await storage.getDirectory().toDart) as _FileSystemDirectoryHandle;
}

