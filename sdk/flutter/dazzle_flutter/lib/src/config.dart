// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

/// Startup configuration for the embedded Valkey server. Maps 1:1 onto
/// `DazzleConfig` in Kotlin / Swift. Serialised to a `Map<String,dynamic>`
/// and handed to the native plugin via method channel.
class DazzleConfig {
  final int    port;
  final String maxMemory;
  final DazzlePersistence persistence;
  final Set<WipeTarget>   wipeOnStart;
  final Set<DazzleModule> modules;
  final String? dataDir;

  const DazzleConfig({
    this.port        = 0,              // 0 = JNI/pipe only, no TCP
    this.maxMemory   = '64mb',
    this.persistence = const AofPersistence(),
    this.wipeOnStart = const <WipeTarget>{},
    this.modules     = const <DazzleModule>{},
    this.dataDir,
  });

  Map<String, dynamic> toMap() => {
        'port':        port,
        'maxMemory':   maxMemory,
        'persistence': persistence.toMap(),
        'wipeOnStart': wipeOnStart.map((e) => e.name).toList(),
        'modules':     modules.map((e) => e.name).toList(),
        if (dataDir != null) 'dataDir': dataDir,
      };
}

sealed class DazzlePersistence {
  const DazzlePersistence();
  Map<String, dynamic> toMap();
}

class NonePersistence extends DazzlePersistence {
  const NonePersistence();
  @override
  Map<String, dynamic> toMap() => const {'kind': 'none'};
}

class AofPersistence extends DazzlePersistence {
  final AppendFsync fsync;
  const AofPersistence({this.fsync = AppendFsync.everysec});
  @override
  Map<String, dynamic> toMap() => {'kind': 'aof', 'fsync': fsync.name};
}

class RdbPersistence extends DazzlePersistence {
  /// List of (seconds, changes) pairs mirroring Valkey `save` directive.
  final List<({int seconds, int changes})> saves;
  const RdbPersistence({this.saves = const []});
  @override
  Map<String, dynamic> toMap() => {
        'kind':  'rdb',
        'saves': saves.map((s) => [s.seconds, s.changes]).toList(),
      };
}

enum AppendFsync { always, everysec, no }

enum WipeTarget { aof, rdb }

/// Loadable modules. On iOS + Android these are compiled into the
/// single binary and loaded via `--loadmodule @static:<name>` when
/// the corresponding flag is set.
enum DazzleModule {
  vectorSearch,   // FT.CREATE / FT.SEARCH (dazzle-search HNSW)
}
