// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Public Flutter Desktop API — same shape as DazzleWeb so apps that
// run both Web and Desktop can share their data layer.  The
// implementation differs (FFI vs js_interop) but the surface area is
// identical: Hash KV + HNSW vector index + binary snapshot
// persistence.
//
// Persistence on Desktop uses a regular file on disk under the app's
// data directory; the host can also pass `snapshotPath:` to override.

import 'dart:io' show File, Directory;
import 'dart:typed_data';

import 'dazzle_lite_bindings.dart';

class DazzleDesktop {
  DazzleDesktop._();

  static DazzleLite? _lib;
  static String _snapshotPath = '';

  /// Open libdazzle_lite and, if a snapshot file exists at
  /// [snapshotPath], restore it.  Defaults the snapshot to
  /// `<cwd>/.dazzle/snapshot.bin` so a quick `flutter run -d macos`
  /// preserves state across reloads.
  ///
  /// On packaged apps callers should pass `snapshotPath:` pointing at
  /// the platform's user-data directory (e.g. via
  /// `path_provider.getApplicationSupportDirectory()`).
  static Future<void> initialize({String? snapshotPath, String? libraryPath}) async {
    if (_lib != null) return;
    _lib = DazzleLite.open(overridePath: libraryPath);

    final defaultDir = Directory('${Directory.current.path}/.dazzle');
    if (!defaultDir.existsSync()) defaultDir.createSync(recursive: true);
    _snapshotPath = snapshotPath ?? '${defaultDir.path}/snapshot.bin';

    final f = File(_snapshotPath);
    if (f.existsSync()) {
      _lib!.loadSnapshot(f.readAsBytesSync());
    }
  }

  static DazzleLite get _l {
    final l = _lib;
    if (l == null) {
      throw StateError('DazzleDesktop.initialize() must complete before calling primitives.');
    }
    return l;
  }

  static DazzleDesktopHash hash(String key) => DazzleDesktopHash._(_l, key);
  static DazzleDesktopVectorIndex vectorIndex(String name) => DazzleDesktopVectorIndex._(_l, name);

  /// Write the current state to [snapshotPath].  Synchronous on
  /// Desktop because the FS write is cheap and atomic-by-rename.
  static Future<void> persist() async {
    final blob = _l.saveSnapshot();
    if (blob.isEmpty) return;
    final tmp = File('$_snapshotPath.tmp');
    tmp.writeAsBytesSync(blob);
    tmp.renameSync(_snapshotPath);
  }

  static Future<void> clearAll() async {
    _l.clear();
    final f = File(_snapshotPath);
    if (f.existsSync()) f.deleteSync();
  }

  static String get version => _l.version();

  /// Tests only.
  static void debugReset() {
    _lib = null;
    _snapshotPath = '';
  }
}

class DazzleDesktopHash {
  final DazzleLite _l;
  final String key;
  DazzleDesktopHash._(this._l, this.key);

  void set(String field, String value) => _l.hset(key, field, value);
  String? get(String field) => _l.hget(key, field);
  bool delete(String field) => _l.hdel(key, field);
  bool exists(String field) => _l.hexists(key, field);
  Map<String, String> getAll() => _l.hgetall(key);
  bool drop() => _l.del(key);
}

class DazzleDesktopVectorIndex {
  final DazzleLite _l;
  final String name;
  DazzleDesktopVectorIndex._(this._l, this.name);

  bool create({required int dim, int M = 16, int efConstruction = 200, int initialCapacity = 1000}) {
    return _l.vsCreate(name, dim: dim, M: M, efConstruction: efConstruction, initialCapacity: initialCapacity);
  }

  bool add(String id, Float32List embedding) => _l.vsAdd(name, id, embedding);

  void addBatch(Map<String, Float32List> items) {
    for (final e in items.entries) _l.vsAdd(name, e.key, e.value);
  }

  List<({String id, double distance})> search(Float32List query, {int topK = 5, int? ef}) {
    return _l.vsSearch(name, query, k: topK, ef: ef);
  }

  bool drop() => _l.vsDrop(name);
}
