// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Raw dart:ffi bindings onto the libdazzle C surface. Mirrors
// `sdk/ios/cshim/include/dazzle_ios.h` one-to-one. Nothing in this file
// is user-facing — the typed API in lib/src/primitives/* / lib/src/ffi/
// dazzle_native.dart wraps these and adds the lifecycle + memory
// management that Dart callers expect.
//
// The same libdazzle.so (Android arm64) and Dazzle.xcframework (iOS
// arm64) binaries the native Kotlin / Swift SDKs load are loaded here —
// this is binding, not re-implementation. Every fix that lands in the
// C core (e.g. the snapshot-cache overflow poison in 1.0.0-beta.3)
// flows into Flutter automatically on the next dazzle_flutter bump.

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Return value of `dazzle_direct_command` / `dazzle_direct_read` — the
/// caller must free with `dazzle_direct_free`.
typedef DazzleDirectCommandNative =
    ffi.Pointer<Utf8> Function(
        ffi.Int32 argc, ffi.Pointer<ffi.Pointer<Utf8>> argv);
typedef DazzleDirectCommand =
    ffi.Pointer<Utf8> Function(int argc, ffi.Pointer<ffi.Pointer<Utf8>> argv);

typedef DazzleDirectFreeNative = ffi.Void Function(ffi.Pointer<Utf8> result);
typedef DazzleDirectFree       = void     Function(ffi.Pointer<Utf8> result);

/// Typed HGETALL — writes field + value pointers into caller-allocated
/// `outFields[]` / `outValues[]`. Each non-null slot is an allocated
/// C string the caller must free with `dazzleDirectFree`.
typedef SnapshotHGetAllNative = ffi.Int32 Function(
    ffi.Pointer<Utf8> key,
    ffi.Pointer<ffi.Pointer<Utf8>> outFields,
    ffi.Pointer<ffi.Pointer<Utf8>> outValues,
    ffi.Int32 maxPairs);
typedef SnapshotHGetAll = int Function(
    ffi.Pointer<Utf8> key,
    ffi.Pointer<ffi.Pointer<Utf8>> outFields,
    ffi.Pointer<ffi.Pointer<Utf8>> outValues,
    int maxPairs);

typedef SnapshotMembersNative = ffi.Int32 Function(
    ffi.Pointer<Utf8> key,
    ffi.Pointer<ffi.Pointer<Utf8>> outMembers,
    ffi.Int32 maxMembers);
typedef SnapshotMembers = int Function(
    ffi.Pointer<Utf8> key,
    ffi.Pointer<ffi.Pointer<Utf8>> outMembers,
    int maxMembers);

typedef SnapshotZRangeByScoreNative = ffi.Int32 Function(
    ffi.Pointer<Utf8> key,
    ffi.Double minScore, ffi.Double maxScore,
    ffi.Pointer<ffi.Pointer<Utf8>> outMembers,
    ffi.Int32 maxMembers);
typedef SnapshotZRangeByScore = int Function(
    ffi.Pointer<Utf8> key,
    double minScore, double maxScore,
    ffi.Pointer<ffi.Pointer<Utf8>> outMembers,
    int maxMembers);

typedef SnapshotGetStringNative = ffi.Int32 Function(
    ffi.Pointer<Utf8> key,
    ffi.Pointer<ffi.Uint8> out,
    ffi.Int32 cap);
typedef SnapshotGetString = int Function(
    ffi.Pointer<Utf8> key,
    ffi.Pointer<ffi.Uint8> out,
    int cap);

// ── Vector index (HNSW) ────────────────────────────────────────────────
//
// These mirror the C helpers the Swift / Kotlin SDKs use for the
// RESP-free fast path. Keeping their signatures here lets Flutter
// consume the same binary without any method-channel round-trip.

typedef VsCreateSq8Native = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8> name, ffi.Int32 dim,
    ffi.Int32 m, ffi.Int32 efConstruction,
    ffi.Int32 initialCap, ffi.Int32 rerank);
typedef VsCreateSq8 = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8> name, int dim, int m, int efConstruction,
    int initialCap, int rerank);

typedef VsCreateF16Native = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8> name, ffi.Int32 dim,
    ffi.Int32 m, ffi.Int32 efConstruction, ffi.Int32 initialCap);
typedef VsCreateF16 = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8> name, int dim, int m, int efConstruction, int initialCap);

typedef VsAddDirectNative = ffi.Void Function(
    ffi.Pointer<Utf8> name,
    ffi.Pointer<Utf8> id, ffi.Int32 idLen,
    ffi.Pointer<ffi.Float> vec);
typedef VsAddDirect = void Function(
    ffi.Pointer<Utf8> name,
    ffi.Pointer<Utf8> id, int idLen,
    ffi.Pointer<ffi.Float> vec);

typedef VsAddBatchDirectNative = ffi.Void Function(
    ffi.Pointer<Utf8> name,
    ffi.Int32 n,
    ffi.Pointer<ffi.Pointer<Utf8>> ids,
    ffi.Pointer<ffi.Int32> idLens,
    ffi.Pointer<ffi.Float> vectorsFlat);
typedef VsAddBatchDirect = void Function(
    ffi.Pointer<Utf8> name,
    int n,
    ffi.Pointer<ffi.Pointer<Utf8>> ids,
    ffi.Pointer<ffi.Int32> idLens,
    ffi.Pointer<ffi.Float> vectorsFlat);

typedef VsOpenHandleNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> name);
typedef VsOpenHandle =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> name);

typedef VsSearchHandleNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> handle,
    ffi.Pointer<ffi.Float> query,
    ffi.Int32 k, ffi.Int32 efRuntime,
    ffi.Pointer<ffi.Pointer<Utf8>> outIds,
    ffi.Pointer<ffi.Float> outDists,
    ffi.Int32 outCap);
typedef VsSearchHandle = int Function(
    ffi.Pointer<ffi.Void> handle,
    ffi.Pointer<ffi.Float> query,
    int k, int efRuntime,
    ffi.Pointer<ffi.Pointer<Utf8>> outIds,
    ffi.Pointer<ffi.Float> outDists,
    int outCap);

typedef VsFreeIdNative = ffi.Void Function(ffi.Pointer<Utf8> id);
typedef VsFreeId       = void     Function(ffi.Pointer<Utf8> id);

// ── LLM (llama.cpp — our patched fork) ─────────────────────────────────
//
// The symbols are statically linked into libdazzle / Dazzle.xcframework
// from our fork of llama.cpp (the same fork the Kotlin / Swift adapters
// drive). Any patch that lands here — e.g. the audio-path bug fix —
// surfaces in Flutter on the next binary rebuild, no Dart code change.

typedef LlamaBackendInitNative = ffi.Void Function();
typedef LlamaBackendInit       = void     Function();

typedef LlamaLoadModelNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> path, ffi.Int32 nGpuLayers);
typedef LlamaLoadModel =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> path, int nGpuLayers);

typedef LlamaFreeModelNative = ffi.Void Function(ffi.Pointer<ffi.Void> model);
typedef LlamaFreeModel       = void     Function(ffi.Pointer<ffi.Void> model);

typedef LlamaNewContextNative =
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void> model,
        ffi.Int32 nCtx, ffi.Int32 nThreads, ffi.Uint32 seed);
typedef LlamaNewContext =
    ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void> model, int nCtx, int nThreads, int seed);

typedef LlamaFreeContextNative =
    ffi.Void Function(ffi.Pointer<ffi.Void> ctx);
typedef LlamaFreeContext = void Function(ffi.Pointer<ffi.Void> ctx);

typedef LlamaGenerateNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> ctx,
    ffi.Pointer<Utf8> prompt,
    ffi.Int32 maxTokens,
    ffi.Float temperature, ffi.Float topP,
    ffi.Pointer<ffi.NativeFunction<
        ffi.Void Function(ffi.Pointer<Utf8>)>> tokenCb);
typedef LlamaGenerate = int Function(
    ffi.Pointer<ffi.Void> ctx,
    ffi.Pointer<Utf8> prompt,
    int maxTokens,
    double temperature, double topP,
    ffi.Pointer<ffi.NativeFunction<
        ffi.Void Function(ffi.Pointer<Utf8>)>> tokenCb);

/// Loaded singleton — looked up lazily on first access to avoid paying
/// the `DynamicLibrary.open` cost at app startup when the dev hasn't
/// actually booted Dazzle yet.
class DazzleBindings {
  DazzleBindings._(this._lib);

  static DazzleBindings? _instance;

  /// First call wins. Subsequent calls return the same binding set —
  /// there's only one libdazzle per process.
  factory DazzleBindings.load() {
    final existing = _instance;
    if (existing != null) return existing;
    final lib = _openLib();
    return _instance = DazzleBindings._(lib);
  }

  static ffi.DynamicLibrary _openLib() {
    if (Platform.isAndroid) {
      // The dazzle_flutter Android plugin depends on the root Dazzle
      // AAR, which ships libdazzle.so inside its jniLibs. Android's
      // dynamic linker resolves the soname at app start.
      return ffi.DynamicLibrary.open('libdazzle.so');
    }
    if (Platform.isIOS || Platform.isMacOS) {
      // Dazzle.xcframework is linked statically into the host binary;
      // process lookup finds its symbols without needing a separate
      // dylib handle.
      return ffi.DynamicLibrary.process();
    }
    throw UnsupportedError(
        'dazzle_flutter currently supports Android and iOS only. '
        'Detected platform: ${Platform.operatingSystem}');
  }

  final ffi.DynamicLibrary _lib;

  // RESP direct path.
  late final DazzleDirectCommand directCommand =
      _lib.lookupFunction<DazzleDirectCommandNative, DazzleDirectCommand>(
          'dazzle_direct_command');
  late final DazzleDirectFree directFree =
      _lib.lookupFunction<DazzleDirectFreeNative, DazzleDirectFree>(
          'dazzle_direct_free');

  // Snapshot cache typed reads.
  late final SnapshotHGetAll snapHGetAll =
      _lib.lookupFunction<SnapshotHGetAllNative, SnapshotHGetAll>(
          'dazzle_snapshot_hgetall_typed');
  late final SnapshotMembers snapSMembers =
      _lib.lookupFunction<SnapshotMembersNative, SnapshotMembers>(
          'dazzle_snapshot_smembers_typed');
  late final SnapshotMembers snapZRangeAll =
      _lib.lookupFunction<SnapshotMembersNative, SnapshotMembers>(
          'dazzle_snapshot_zrange_all_typed');
  late final SnapshotZRangeByScore snapZRangeByScore = _lib.lookupFunction<
      SnapshotZRangeByScoreNative, SnapshotZRangeByScore>(
      'dazzle_snapshot_zrange_by_score_typed');
  late final SnapshotGetString snapGetString = _lib.lookupFunction<
      SnapshotGetStringNative, SnapshotGetString>(
      'dazzle_snapshot_get_string_typed');

  // Vector index.
  late final VsCreateSq8 vsCreateSq8 =
      _lib.lookupFunction<VsCreateSq8Native, VsCreateSq8>(
          'dazzle_vs_create_sq8');
  late final VsCreateF16 vsCreateF16 =
      _lib.lookupFunction<VsCreateF16Native, VsCreateF16>(
          'dazzle_vs_create_f16');
  late final VsAddDirect vsAddDirect =
      _lib.lookupFunction<VsAddDirectNative, VsAddDirect>(
          'dazzle_vs_add_direct');
  late final VsAddBatchDirect vsAddBatchDirect = _lib.lookupFunction<
      VsAddBatchDirectNative, VsAddBatchDirect>(
      'dazzle_vs_add_batch_direct');
  late final VsOpenHandle vsOpenHandle =
      _lib.lookupFunction<VsOpenHandleNative, VsOpenHandle>(
          'dazzle_vs_open_handle');
  late final VsSearchHandle vsSearchHandle =
      _lib.lookupFunction<VsSearchHandleNative, VsSearchHandle>(
          'dazzle_vs_search_handle');
  late final VsFreeId vsFreeId =
      _lib.lookupFunction<VsFreeIdNative, VsFreeId>('dazzle_vs_free_id');

  // Llama.cpp (our fork).
  late final LlamaBackendInit llamaBackendInit =
      _lib.lookupFunction<LlamaBackendInitNative, LlamaBackendInit>(
          'dazzle_llama_backend_init');
  late final LlamaLoadModel llamaLoadModel =
      _lib.lookupFunction<LlamaLoadModelNative, LlamaLoadModel>(
          'dazzle_llama_load_model');
  late final LlamaFreeModel llamaFreeModel =
      _lib.lookupFunction<LlamaFreeModelNative, LlamaFreeModel>(
          'dazzle_llama_free_model');
  late final LlamaNewContext llamaNewContext =
      _lib.lookupFunction<LlamaNewContextNative, LlamaNewContext>(
          'dazzle_llama_new_context');
  late final LlamaFreeContext llamaFreeContext =
      _lib.lookupFunction<LlamaFreeContextNative, LlamaFreeContext>(
          'dazzle_llama_free_context');
  late final LlamaGenerate llamaGenerate =
      _lib.lookupFunction<LlamaGenerateNative, LlamaGenerate>(
          'dazzle_llama_generate');
}
