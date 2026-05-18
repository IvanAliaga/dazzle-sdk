// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// End-to-end test for the Desktop FFI bridge — opens libdazzle_lite,
// calls every wrapped function, and validates the round-trip semantics
// match the WASM build.  This is a pure-Dart unit test (not a Flutter
// integration test) so it runs under the standard `dart test` runner
// against the host platform's libdazzle_lite.{dylib,so,dll}.
//
// The library path is resolved by walking up to the repo root and
// pointing at the build artefact produced by `core/native-lite/build.sh`.

@TestOn('vm')
library;

import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:dazzle_flutter/src/desktop/dazzle_lite_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DazzleLite lib;

  setUpAll(() {
    final libPath = _resolveLibraryPath();
    expect(File(libPath).existsSync(), isTrue,
        reason: 'libdazzle_lite not found at $libPath — run core/native-lite/build.sh first');
    lib = DazzleLite.open(overridePath: libPath);
  });

  setUp(() {
    lib.clear();
  });

  group('DazzleLite — diagnostics', () {
    test('version returns build identifier', () {
      final v = lib.version();
      expect(v, contains('dazzle-wasm'));
    });
  });

  group('DazzleLite — Hash KV', () {
    test('hset / hget round-trip', () {
      expect(lib.hset('chat:1', 'role', 'user'), isTrue);
      expect(lib.hget('chat:1', 'role'), 'user');
    });

    test('hget returns null for missing field', () {
      expect(lib.hget('nope', 'whatever'), isNull);
    });

    test('hgetall returns every pair', () {
      lib.hset('chat:m', 'role', 'user');
      lib.hset('chat:m', 'text', 'hello');
      lib.hset('chat:m', 'lang', 'es');

      final all = lib.hgetall('chat:m');
      expect(all, hasLength(3));
      expect(all['role'], 'user');
      expect(all['text'], 'hello');
      expect(all['lang'], 'es');
    });

    test('hdel removes a single field; del removes the whole hash', () {
      lib.hset('h', 'a', '1');
      lib.hset('h', 'b', '2');
      expect(lib.hdel('h', 'a'), isTrue);
      expect(lib.hexists('h', 'a'), isFalse);
      expect(lib.hexists('h', 'b'), isTrue);
      expect(lib.del('h'), isTrue);
      expect(lib.hgetall('h'), isEmpty);
    });
  });

  group('DazzleLite — Vector index', () {
    test('create + add + search returns nearest first', () {
      expect(lib.vsCreate('cat', dim: 4), isTrue);
      lib.vsAdd('cat', 'a', Float32List.fromList([1, 0, 0, 0]));
      lib.vsAdd('cat', 'b', Float32List.fromList([0, 1, 0, 0]));
      lib.vsAdd('cat', 'c', Float32List.fromList([0, 0, 1, 0]));

      final hits = lib.vsSearch('cat', Float32List.fromList([0.95, 0.05, 0, 0]), k: 2);
      expect(hits, hasLength(2));
      expect(hits.first.id, 'a');
      expect(hits.first.distance, lessThan(hits.last.distance));
    });

    test('drop removes the index', () {
      lib.vsCreate('drop-me', dim: 2);
      expect(lib.vsDrop('drop-me'), isTrue);
      expect(lib.vsCreate('drop-me', dim: 2), isTrue);   // re-create works
    });
  });

  group('DazzleLite — Snapshot round-trip', () {
    test('save then load restores hashes and vectors', () {
      lib.hset('persist', 'a', '1');
      lib.hset('persist', 'b', '2');
      lib.vsCreate('vec', dim: 3);
      lib.vsAdd('vec', 'p', Float32List.fromList([1.0, 0.0, 0.0]));
      lib.vsAdd('vec', 'q', Float32List.fromList([0.0, 1.0, 0.0]));

      final blob = lib.saveSnapshot();
      expect(blob.length, greaterThan(8));
      // "DZWS" magic.
      expect(blob.sublist(0, 4), equals([0x44, 0x5A, 0x57, 0x53]));

      lib.clear();
      expect(lib.hget('persist', 'a'), isNull);

      expect(lib.loadSnapshot(blob), isTrue);
      expect(lib.hget('persist', 'a'), '1');
      expect(lib.hget('persist', 'b'), '2');

      final hits = lib.vsSearch('vec', Float32List.fromList([1.0, 0.0, 0.0]), k: 1);
      expect(hits, hasLength(1));
      expect(hits.first.id, 'p');
    });
  });
}

String _resolveLibraryPath() {
  // Allow CI / users to override via env var (CI sets this after the
  // matrix native-lite job stages the artefact under a known path).
  final fromEnv = Platform.environment['DAZZLE_LITE_PATH'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

  // `flutter test` runs from the package root (sdk/flutter/dazzle_flutter).
  // Walk up to the repo root by looking for the marker.
  final repoRoot = _findRepoRoot();
  final buildDir = '$repoRoot/core/native-lite/build';
  if (Platform.isMacOS)   return '$buildDir/libdazzle_lite.dylib';
  if (Platform.isLinux)   return '$buildDir/libdazzle_lite.so';
  if (Platform.isWindows) return '$buildDir/dazzle_lite.dll';
  throw UnsupportedError('Unsupported test platform ${Platform.operatingSystem}');
}

String _findRepoRoot() {
  // Start from CWD (where flutter test was invoked).
  var dir = Directory.current.path;
  for (var i = 0; i < 12; i++) {
    if (File('$dir/core/native-lite/CMakeLists.txt').existsSync()) return dir;
    final parent = File(dir).parent.path;
    if (parent == dir) break;
    dir = parent;
  }
  throw StateError(
      'Could not locate the dazzle-sdk repo root from ${Directory.current.path}. '
      'Set DAZZLE_LITE_PATH env var to the absolute path of libdazzle_lite.{dylib,so,dll}.');
}
