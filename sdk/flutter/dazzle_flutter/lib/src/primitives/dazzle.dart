// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Dazzle client facade — the factory every primitive hangs off of.
// Mirrors `Dazzle` in Kotlin / `Dazzle` in Swift.

import 'hash.dart';
import 'list.dart';
import 'set.dart';
import 'sorted_set.dart';
import 'stream.dart';
import 'string.dart';

/// Typed wrapper over the Dazzle keyspace. Each primitive factory
/// returns a lightweight handle tied to a single key; the handle holds
/// no state beyond the key name and delegates to the shared FFI layer.
class Dazzle {
  Dazzle._();

  /// Package-private constructor used by the lib entry point.
  // ignore: library_private_types_in_public_api
  factory Dazzle() => _instance;

  static final Dazzle _instance = Dazzle._();

  /// Internal use: DazzleServer hands back this cached instance.
  // ignore: library_private_types_in_public_api
  static Dazzle internalFromServer() => _instance;

  HashKey       hash(String key)       => HashKey(key);
  SortedSetKey  sortedSet(String key)  => SortedSetKey(key);
  SetKey        set(String key)        => SetKey(key);
  StringKey     string(String key)     => StringKey(key);
  ListKey       list(String key)       => ListKey(key);
  StreamKey     stream(String key)     => StreamKey(key);
}
