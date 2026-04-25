// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// DazzleServer — Dart facade for the embedded Valkey server that lives
// inside libdazzle / Dazzle.xcframework.
//
// Lifecycle (start/stop/isRunning) goes through a Flutter method
// channel, because the native Kotlin / Swift startup sequence is a
// multi-step ceremony (spawn a worker thread that runs valkey-main
// with a crafted argv, wait for `Server initialized`, attach the
// in-process mirror). That's already correctly implemented on the
// native side — we'd only be reimplementing it worse in Dart.
//
// Everything *else* — the millions of `HSET` / `HGETALL` / `ZADD` /
// `FT.SEARCH` calls that happen after start — goes through dart:ffi
// directly. No method-channel overhead on the hot path.

import 'dart:async';

import 'package:flutter/services.dart';

import 'config.dart';
import 'primitives/dazzle.dart';

const MethodChannel _channel = MethodChannel('dev.dazzle.flutter');

/// Embedded Dazzle server — one per process. Exactly one `start` can
/// be in flight; subsequent calls return the already-running server
/// handle (matching Kotlin `DazzleServer` and Swift `DazzleServer.shared`).
class DazzleServer {
  DazzleServer._();

  static final DazzleServer shared = DazzleServer._();
  static bool _started = false;

  /// Lazily built, cached client facade. Same shape as Kotlin
  /// `DazzleServer.client()` / Swift `server.client()`.
  final Dazzle _client = Dazzle.internalFromServer();

  /// Boot the embedded Valkey server. Idempotent — calling twice is
  /// a no-op on the native side, but we still await so the Dart-side
  /// barrier is honoured.
  ///
  /// Call from `main()` or the first widget that touches Dazzle.
  Future<void> start({DazzleConfig config = const DazzleConfig()}) async {
    if (_started) return;
    await _channel.invokeMethod<void>('start', config.toMap());
    _started = true;
  }

  /// Graceful shutdown (SHUTDOWN command). Call on app teardown if you
  /// need the AOF to fsync before the process exits; otherwise the OS
  /// reap is fine and the AOF replays cleanly on next boot.
  Future<void> stop() async {
    if (!_started) return;
    await _channel.invokeMethod<void>('stop');
    _started = false;
  }

  /// `true` once the server has finished booting.
  bool get isRunning => _started;

  /// Wait until `start()` completes. Equivalent to Kotlin's
  /// `DazzleServer.waitForReady(timeout)`. On Flutter we just await
  /// the start future since it only resolves after the native side
  /// has the server ready.
  Future<bool> waitForReady({Duration timeout = const Duration(seconds: 5)}) async {
    if (_started) return true;
    try {
      final ok = await _channel
          .invokeMethod<bool>('waitForReady', {'timeoutMs': timeout.inMilliseconds});
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Client facade — where all the typed primitives live.
  Dazzle client() => _client;
}
