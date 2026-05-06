// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// dart:ffi bindings for libdazzle_lite — the native shared library
// that mirrors the dazzle.wasm Flutter Web uses, compiled from the
// SAME C++ source (core/web/src/dazzle_wasm.cpp).  The CMake target
// in core/native-lite/ produces:
//
//   - libdazzle_lite.so      (Linux x64 / arm64)
//   - libdazzle_lite.dylib   (macOS arm64 / x64)
//   - dazzle_lite.dll        (Windows x64)
//
// The plugin's per-platform CMakeLists copies the pre-built binary
// into the bundled assets so apps consuming `dazzle_flutter` don't
// need a host C++ toolchain.

import 'dart:ffi' as ffi;
import 'dart:io' show Platform, File;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// C function signatures.
// ---------------------------------------------------------------------------

typedef _HsetC = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _HsetD = int       Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _HgetC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _HgetD = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _HdelC = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _HdelD = int       Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _HexistsC = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _HexistsD = int       Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _HgetAllC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _HgetAllD = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

typedef _DelC = ffi.Int32 Function(ffi.Pointer<Utf8>);
typedef _DelD = int       Function(ffi.Pointer<Utf8>);

typedef _VsCreateC = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Int32);
typedef _VsCreateD = int       Function(ffi.Pointer<Utf8>, int, int, int, int);

typedef _VsAddC = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Float>);
typedef _VsAddD = int       Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Float>);

typedef _VsSearchC = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Float>, ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _VsSearchD = int       Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Float>, int, int, ffi.Pointer<ffi.Float>, int);

typedef _VsSearchIdsC = ffi.Pointer<Utf8> Function();
typedef _VsSearchIdsD = ffi.Pointer<Utf8> Function();

typedef _VsDropC = ffi.Int32 Function(ffi.Pointer<Utf8>);
typedef _VsDropD = int       Function(ffi.Pointer<Utf8>);

typedef _SaveSnapshotC = ffi.Int32 Function(ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Int32>);
typedef _SaveSnapshotD = int       Function(ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Int32>);

typedef _LoadSnapshotC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _LoadSnapshotD = int       Function(ffi.Pointer<ffi.Uint8>, int);

typedef _VoidC = ffi.Void Function();
typedef _VoidD = void     Function();

typedef _ClearC = ffi.Int32 Function();
typedef _ClearD = int       Function();

typedef _VersionC = ffi.Pointer<Utf8> Function();
typedef _VersionD = ffi.Pointer<Utf8> Function();

// ---------------------------------------------------------------------------
// DazzleLite — typed wrapper around libdazzle_lite.
// ---------------------------------------------------------------------------

class DazzleLite {
  final ffi.DynamicLibrary _lib;

  late final _HsetD         _hset;
  late final _HgetD         _hget;
  late final _HdelD         _hdel;
  late final _HexistsD      _hexists;
  late final _HgetAllD      _hgetall;
  late final _DelD          _del;
  late final _VsCreateD     _vsCreate;
  late final _VsAddD        _vsAdd;
  late final _VsSearchD     _vsSearch;
  late final _VsSearchIdsD  _vsSearchIds;
  late final _VsDropD       _vsDrop;
  late final _SaveSnapshotD _saveSnapshot;
  late final _LoadSnapshotD _loadSnapshot;
  late final _VoidD         _snapshotRelease;
  late final _ClearD        _clear;
  late final _VersionD      _version;

  DazzleLite._(this._lib) {
    _hset            = _lib.lookupFunction<_HsetC,         _HsetD>        ('dazzle_hset');
    _hget            = _lib.lookupFunction<_HgetC,         _HgetD>        ('dazzle_hget');
    _hdel            = _lib.lookupFunction<_HdelC,         _HdelD>        ('dazzle_hdel');
    _hexists         = _lib.lookupFunction<_HexistsC,      _HexistsD>     ('dazzle_hexists');
    _hgetall         = _lib.lookupFunction<_HgetAllC,      _HgetAllD>     ('dazzle_hgetall');
    _del             = _lib.lookupFunction<_DelC,          _DelD>         ('dazzle_del');
    _vsCreate        = _lib.lookupFunction<_VsCreateC,     _VsCreateD>    ('dazzle_vs_create');
    _vsAdd           = _lib.lookupFunction<_VsAddC,        _VsAddD>       ('dazzle_vs_add');
    _vsSearch        = _lib.lookupFunction<_VsSearchC,     _VsSearchD>    ('dazzle_vs_search');
    _vsSearchIds     = _lib.lookupFunction<_VsSearchIdsC,  _VsSearchIdsD> ('dazzle_vs_search_ids');
    _vsDrop          = _lib.lookupFunction<_VsDropC,       _VsDropD>      ('dazzle_vs_drop');
    _saveSnapshot    = _lib.lookupFunction<_SaveSnapshotC, _SaveSnapshotD>('dazzle_save_snapshot');
    _loadSnapshot    = _lib.lookupFunction<_LoadSnapshotC, _LoadSnapshotD>('dazzle_load_snapshot');
    _snapshotRelease = _lib.lookupFunction<_VoidC,         _VoidD>        ('dazzle_snapshot_release');
    _clear           = _lib.lookupFunction<_ClearC,        _ClearD>       ('dazzle_clear');
    _version         = _lib.lookupFunction<_VersionC,      _VersionD>     ('dazzle_version');
  }

  /// Open the platform-appropriate libdazzle_lite.  In a packaged
  /// Flutter Desktop app the binary lives next to the executable; in
  /// dev / tests it lives under the plugin's per-platform native dir.
  factory DazzleLite.open({String? overridePath}) {
    final path = overridePath ?? _resolveDefaultPath();
    final lib = ffi.DynamicLibrary.open(path);
    return DazzleLite._(lib);
  }

  static String _resolveDefaultPath() {
    if (Platform.isMacOS)   return _firstExisting(['libdazzle_lite.dylib', 'Frameworks/libdazzle_lite.dylib']);
    if (Platform.isLinux)   return _firstExisting(['libdazzle_lite.so',    'native/libdazzle_lite.so']);
    if (Platform.isWindows) return _firstExisting(['dazzle_lite.dll',      'native\\dazzle_lite.dll']);
    throw UnsupportedError('DazzleLite: unsupported platform ${Platform.operatingSystem}');
  }

  static String _firstExisting(List<String> candidates) {
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    // Fall back to the first candidate; DynamicLibrary.open will throw
    // a clear error if it's missing.
    return candidates.first;
  }

  // -------------- Hash KV --------------

  bool hset(String key, String field, String value) {
    final pK = key.toNativeUtf8();
    final pF = field.toNativeUtf8();
    final pV = value.toNativeUtf8();
    try {
      return _hset(pK, pF, pV) > 0;
    } finally {
      calloc.free(pK); calloc.free(pF); calloc.free(pV);
    }
  }

  String? hget(String key, String field) {
    final pK = key.toNativeUtf8();
    final pF = field.toNativeUtf8();
    try {
      final ret = _hget(pK, pF);
      if (ret == ffi.nullptr) return null;
      return ret.toDartString();
    } finally {
      calloc.free(pK); calloc.free(pF);
    }
  }

  bool hdel(String key, String field) {
    final pK = key.toNativeUtf8();
    final pF = field.toNativeUtf8();
    try {
      return _hdel(pK, pF) > 0;
    } finally {
      calloc.free(pK); calloc.free(pF);
    }
  }

  bool hexists(String key, String field) {
    final pK = key.toNativeUtf8();
    final pF = field.toNativeUtf8();
    try {
      return _hexists(pK, pF) == 1;
    } finally {
      calloc.free(pK); calloc.free(pF);
    }
  }

  Map<String, String> hgetall(String key) {
    final pK = key.toNativeUtf8();
    try {
      final ret = _hgetall(pK);
      if (ret == ffi.nullptr) return const {};
      // toDartString stops at the first NUL; we read raw bytes instead
      // because the library returns "f1\0v1\0f2\0v2\0".
      return _readZeroSeparatedPairs(ret.cast<ffi.Uint8>());
    } finally {
      calloc.free(pK);
    }
  }

  Map<String, String> _readZeroSeparatedPairs(ffi.Pointer<ffi.Uint8> p) {
    if (p == ffi.nullptr) return const {};
    int end = 0;
    const cap = 1 << 20;
    while (end < cap && (p[end] != 0 || (end > 0 && p[end - 1] != 0))) {
      end++;
    }
    final bytes = p.asTypedList(end);
    final raw = String.fromCharCodes(bytes);
    final parts = raw.split(String.fromCharCode(0))..removeWhere((s) => s.isEmpty);
    final out = <String, String>{};
    for (var i = 0; i + 1 < parts.length; i += 2) {
      out[parts[i]] = parts[i + 1];
    }
    return out;
  }

  bool del(String key) {
    final pK = key.toNativeUtf8();
    try {
      return _del(pK) > 0;
    } finally {
      calloc.free(pK);
    }
  }

  // -------------- Vector index --------------

  bool vsCreate(String name, {required int dim, int M = 16, int efConstruction = 200, int initialCapacity = 1000}) {
    final pN = name.toNativeUtf8();
    try {
      return _vsCreate(pN, dim, M, efConstruction, initialCapacity) > 0;
    } finally {
      calloc.free(pN);
    }
  }

  bool vsAdd(String name, String id, Float32List embedding) {
    final pN = name.toNativeUtf8();
    final pI = id.toNativeUtf8();
    final pE = calloc<ffi.Float>(embedding.length);
    try {
      pE.asTypedList(embedding.length).setAll(0, embedding);
      return _vsAdd(pN, pI, pE) > 0;
    } finally {
      calloc.free(pN); calloc.free(pI); calloc.free(pE);
    }
  }

  List<({String id, double distance})> vsSearch(String name, Float32List query, {int k = 5, int? ef}) {
    final pN = name.toNativeUtf8();
    final pQ = calloc<ffi.Float>(query.length);
    final pD = calloc<ffi.Float>(k);
    try {
      pQ.asTypedList(query.length).setAll(0, query);
      final n = _vsSearch(pN, pQ, k, ef ?? -1, pD, k);
      if (n <= 0) return const [];

      final idsPtr = _vsSearchIds();
      final ids = _readZeroSeparatedList(idsPtr.cast<ffi.Uint8>());
      final dists = pD.asTypedList(n);
      return [
        for (var i = 0; i < n && i < ids.length; i++)
          (id: ids[i], distance: dists[i].toDouble())
      ];
    } finally {
      calloc.free(pN); calloc.free(pQ); calloc.free(pD);
    }
  }

  List<String> _readZeroSeparatedList(ffi.Pointer<ffi.Uint8> p) {
    if (p == ffi.nullptr) return const [];
    int end = 0;
    const cap = 1 << 20;
    while (end < cap && (p[end] != 0 || (end > 0 && p[end - 1] != 0))) {
      end++;
    }
    final raw = String.fromCharCodes(p.asTypedList(end));
    return raw.split(String.fromCharCode(0))..removeWhere((s) => s.isEmpty);
  }

  bool vsDrop(String name) {
    final pN = name.toNativeUtf8();
    try {
      return _vsDrop(pN) > 0;
    } finally {
      calloc.free(pN);
    }
  }

  // -------------- Snapshot --------------

  Uint8List saveSnapshot() {
    final pBuf = calloc<ffi.Pointer<ffi.Uint8>>();
    final pLen = calloc<ffi.Int32>();
    try {
      final ok = _saveSnapshot(pBuf, pLen);
      if (ok != 1) return Uint8List(0);
      final ptr = pBuf.value;
      final len = pLen.value;
      final out = Uint8List.fromList(ptr.asTypedList(len));
      _snapshotRelease();
      return out;
    } finally {
      calloc.free(pBuf); calloc.free(pLen);
    }
  }

  bool loadSnapshot(Uint8List bytes) {
    final p = calloc<ffi.Uint8>(bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      return _loadSnapshot(p, bytes.length) == 1;
    } finally {
      calloc.free(p);
    }
  }

  void clear() => _clear();

  String version() => _version().toDartString();
}
