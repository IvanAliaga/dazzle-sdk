// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Typed wrapper around the dazzle-search HNSW module. Mirrors
// `VectorIndex.kt` / `VectorIndex.swift`. The direct fast-path
// (`addBatchDirect`, `searchDirect`) goes through dart:ffi to the C
// helpers that hnswlib exposes — zero RESP, zero base64, fp32 crosses
// as a raw float buffer.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../ffi/bindings.dart';
import '../ffi/command.dart';
import '../server.dart';

enum VectorAlgorithm { flat, hnsw, hnswSq8, hnswSq8Rerank, hnswF16 }
enum VectorMetric { cosine, l2, ip }

class VectorSearchResult {
  final String id;
  final double distance;
  const VectorSearchResult({required this.id, required this.distance});
  @override
  String toString() => 'VectorSearchResult(id=$id, dist=$distance)';
}

class VectorIndex {
  VectorIndex._({
    required this.name,
    required this.hashPrefix,
    required this.vectorField,
    required this.dim,
    required this.algorithm,
    required this.metric,
    this.m = 0,
    this.efConstruction = 0,
  });

  final String name;
  final String hashPrefix;
  final String vectorField;
  final int    dim;
  final VectorAlgorithm algorithm;
  final VectorMetric metric;
  final int m;
  final int efConstruction;

  ffi.Pointer<ffi.Void>? _cachedHandle;

  /// Factory — registered on DazzleServer.client() so API matches
  /// Kotlin / Swift calls exactly.
  static VectorIndex create({
    required String name,
    required String hashPrefix,
    String vectorField = 'embedding',
    required int dim,
    VectorAlgorithm algorithm = VectorAlgorithm.hnsw,
    VectorMetric metric = VectorMetric.cosine,
    int m = 0,
    int efConstruction = 0,
    int initialCapacity = 0,
  }) {
    final idx = VectorIndex._(
      name: name, hashPrefix: hashPrefix, vectorField: vectorField,
      dim: dim, algorithm: algorithm, metric: metric,
      m: m, efConstruction: efConstruction,
    );
    idx._createOnServer(initialCapacity: initialCapacity);
    return idx;
  }

  bool _createOnServer({int initialCapacity = 0}) {
    final bindings = DazzleBindings.load();
    final mArg  = m > 0 ? m : 32;
    final efArg = efConstruction > 0 ? efConstruction : 400;
    final capArg = initialCapacity;

    final namePtr = name.toNativeUtf8();
    try {
      switch (algorithm) {
        case VectorAlgorithm.hnswSq8:
        case VectorAlgorithm.hnswSq8Rerank:
          _requireCosine();
          _cachedHandle = bindings.vsCreateSq8(
              namePtr, dim, mArg, efArg, capArg,
              algorithm == VectorAlgorithm.hnswSq8Rerank ? 1 : 0);
          return _cachedHandle != ffi.nullptr;
        case VectorAlgorithm.hnswF16:
          _requireCosine();
          _cachedHandle =
              bindings.vsCreateF16(namePtr, dim, mArg, efArg, capArg);
          return _cachedHandle != ffi.nullptr;
        case VectorAlgorithm.flat:
        case VectorAlgorithm.hnsw:
          // RESP FT.CREATE path — same as native SDK.
          return _respFtCreate(initialCapacity: initialCapacity);
      }
    } finally {
      calloc.free(namePtr);
    }
  }

  void _requireCosine() {
    if (metric != VectorMetric.cosine) {
      throw ArgumentError(
          '$algorithm only supports VectorMetric.cosine — got $metric');
    }
  }

  bool _respFtCreate({required int initialCapacity}) {
    final algoStr = algorithm == VectorAlgorithm.flat ? 'FLAT' : 'HNSW';
    final metricStr = switch (metric) {
      VectorMetric.cosine => 'COSINE',
      VectorMetric.l2     => 'L2',
      VectorMetric.ip     => 'IP',
    };
    final args = <String>[
      'FT.CREATE', name,
      'ON', 'HASH',
      'PREFIX', '1', hashPrefix,
      'SCHEMA',
      vectorField, 'VECTOR', algoStr,
      '6',
      'TYPE', 'FLOAT32',
      'DIM', '$dim',
      'DISTANCE_METRIC', metricStr,
    ];
    if (initialCapacity > 0) args..add('INITIAL_CAP')..add('$initialCapacity');
    if (m > 0)               args..add('M')..add('$m');
    if (efConstruction > 0)  args..add('EF_CONSTRUCTION')..add('$efConstruction');

    try {
      final r = dazzleCommand(args);
      if (r case RespError(:final message)) {
        return message.toLowerCase().contains('already');
      }
      return true;
    } on DazzleTransportException {
      return false;
    }
  }

  // MARK: – Add

  /// Add a single vector by the direct fast-path.
  void addDirect(String id, List<double> vector) {
    if (vector.length != dim) {
      throw ArgumentError('vector length ${vector.length} != dim $dim');
    }
    final bindings = DazzleBindings.load();
    final namePtr = name.toNativeUtf8();
    final idPtr = id.toNativeUtf8();
    final vecBuf = calloc<ffi.Float>(dim);
    try {
      for (var i = 0; i < dim; i++) {
        vecBuf[i] = vector[i];
      }
      bindings.vsAddDirect(namePtr, idPtr, id.length, vecBuf);
    } finally {
      calloc.free(vecBuf);
      calloc.free(idPtr);
      calloc.free(namePtr);
    }
  }

  /// Bulk add — one C crossing for N vectors. Flattens into a single
  /// contiguous float buffer like the native SDKs.
  void addBatchDirect(List<String> ids, List<List<double>> vectors) {
    if (ids.length != vectors.length) {
      throw ArgumentError('ids.length != vectors.length');
    }
    final n = ids.length;
    if (n == 0) return;

    final bindings = DazzleBindings.load();
    final namePtr = name.toNativeUtf8();
    final idsPtr  = calloc<ffi.Pointer<Utf8>>(n);
    final lensPtr = calloc<ffi.Int32>(n);
    final flat    = calloc<ffi.Float>(n * dim);
    final tempIds = <ffi.Pointer<Utf8>>[];
    try {
      for (var i = 0; i < n; i++) {
        final p = ids[i].toNativeUtf8();
        tempIds.add(p);
        idsPtr[i]  = p;
        lensPtr[i] = ids[i].length;
        final v = vectors[i];
        if (v.length != dim) {
          throw ArgumentError(
              'vectors[$i] length ${v.length} != dim $dim');
        }
        for (var j = 0; j < dim; j++) {
          flat[i * dim + j] = v[j];
        }
      }
      bindings.vsAddBatchDirect(namePtr, n, idsPtr, lensPtr, flat);
    } finally {
      for (final p in tempIds) {
        calloc.free(p);
      }
      calloc.free(flat);
      calloc.free(lensPtr);
      calloc.free(idsPtr);
      calloc.free(namePtr);
    }
  }

  // MARK: – Search

  /// Direct fast-path KNN. `efRuntime > 0` uses the per-call
  /// `searchKnnEf` overload so concurrent queries don't contend on
  /// a shared `ef_` field.
  List<VectorSearchResult> searchDirect(List<double> query,
      {int k = 10, int efRuntime = 0}) {
    if (query.length != dim) {
      throw ArgumentError('query length ${query.length} != dim $dim');
    }
    final bindings = DazzleBindings.load();
    if (_cachedHandle == null) {
      final namePtr = name.toNativeUtf8();
      try {
        _cachedHandle = bindings.vsOpenHandle(namePtr);
      } finally {
        calloc.free(namePtr);
      }
    }
    final handle = _cachedHandle;
    if (handle == null || handle == ffi.nullptr) {
      return const [];
    }

    final qp = calloc<ffi.Float>(dim);
    final outIds  = calloc<ffi.Pointer<Utf8>>(k);
    final outDist = calloc<ffi.Float>(k);
    try {
      for (var i = 0; i < dim; i++) {
        qp[i] = query[i];
      }
      final n = bindings.vsSearchHandle(
          handle, qp, k, efRuntime, outIds, outDist, k);

      final result = <VectorSearchResult>[];
      for (var i = 0; i < n; i++) {
        final p = outIds[i];
        if (p != ffi.nullptr) {
          result.add(VectorSearchResult(
            id: p.toDartString(),
            distance: outDist[i],
          ));
          bindings.vsFreeId(p);
        }
      }
      return result;
    } finally {
      calloc.free(outDist);
      calloc.free(outIds);
      calloc.free(qp);
    }
  }
}

// Bolt-on extension so `DazzleServer.shared.client().vectorIndex(...)`
// reads identically to the Kotlin / Swift API.
extension VectorIndexOnServer on DazzleServer {
  VectorIndex vectorIndex({
    required String name,
    required String hashPrefix,
    String vectorField = 'embedding',
    required int dim,
    VectorAlgorithm algorithm = VectorAlgorithm.hnsw,
    VectorMetric metric = VectorMetric.cosine,
    int m = 0,
    int efConstruction = 0,
    int initialCapacity = 0,
  }) =>
      VectorIndex.create(
        name: name, hashPrefix: hashPrefix, vectorField: vectorField,
        dim: dim, algorithm: algorithm, metric: metric,
        m: m, efConstruction: efConstruction,
        initialCapacity: initialCapacity,
      );
}
