# Storage layer

How data is laid out in memory, on the wire (RESP), and on disk
(snapshot blob, AOF, RDB).

## Two runtimes, one mental model

Dazzle has two distinct storage runtimes that share an API but not
an implementation:

1. **Mobile** (iOS / Android / Flutter mobile / RN mobile / .NET
   sidecar): the full Valkey 9.0.3 server runs in-process. Hash
   slots, dict resizing, AOF, RDB, replication primitives — all
   present, even if some are dormant.
2. **Lite** (Flutter Web / RN Web / React DOM / Flutter Desktop /
   C++ servers): a single-translation-unit C++ implementation with
   `std::unordered_map<key, std::unordered_map<field, value>>` and
   a pinned `hnswlib` HNSW index. No RESP, no networking, no
   replication.

Both runtimes serialise via the **same `DZWS` snapshot format**, so
a snapshot saved by one can be read by the other.

## Hash KV — the workhorse

Every Dazzle app's chat memory, RAG metadata and config live in
hashes. The wire-format is the standard Valkey/Redis hash:

```
HSET   key field value           # 1 if added, 0 if updated
HGET   key field                 # value or nil
HDEL   key field                 # 1 if deleted, 0 otherwise
HEXISTS key field                # 1 / 0
HGETALL key                      # all field/value pairs
DEL    key                       # drops the entire hash
```

### Mobile internals

Valkey stores hashes as either:

- A **listpack** (compact contiguous block) when the hash is small
  (≤128 fields, all values <64 bytes, by default). O(N) lookups
  but extremely cache-friendly.
- A **hashtable** (`dict.c` open-addressing-with-chaining) when
  it grows beyond the listpack threshold. O(1) amortised, with
  incremental rehash on the next operation.

The thresholds live in `valkey.conf` as `hash-max-listpack-entries`
and `hash-max-listpack-value`.

### Lite runtime internals

The lite C++ runtime uses `std::unordered_map<std::string,
std::unordered_map<std::string, std::string>>` directly. No
listpack tier (the implementation cost wasn't justified for the
subset). For typical chat-memory workloads (≤200 turns per
conversation, ≤100 chars per field) this is fine; for tens of
thousands of fields under one key, mobile's listpack→hashtable
promotion is faster.

### Hot path on mobile — the snapshot cache

`HashKey.getAllDirect()` (Kotlin / Swift / Dart) skips the RESP
round-trip entirely. It reads the in-process snapshot mirror via
FFI / JNI and returns a `Map<String, String>` in **~30 µs** on an
A14 (`iPhone 12 Pro`). The path is:

```
HashKey.getAllDirect()
    └─ JNI/FFI → dazzle_snapshot_hgetall_typed()
        └─ direct read from the dict pointer the server thread also writes to
```

The snapshot mirror is updated by the writer thread on every HSET
under a fine-grained lock. Readers don't block writers. See
[threading-model.md](./threading-model.md) for the full
locking diagram.

## Sorted Sets, Streams, Lists, Sets, Strings — mobile only

These primitives live entirely in the Valkey embedding. They
follow the standard wire protocol and inherit Valkey's data
structures:

- **SortedSet** — listpack for small sets, skiplist + hashtable for
  large. `ZRANGEBYSCORE`, `ZADD`, `ZREVRANGE` all O(log N + k).
- **Stream** — radix tree of stream entries indexed by ID, with
  consumer groups in a separate dict. `XADD`, `XREAD`, `XRANGE`.
- **List** — quicklist (a linked list of listpacks). O(1) ends,
  O(N) middle.
- **Set** — listpack for small; intset for all-integer; hashtable
  for everything else.
- **String** — an `sds` (simple dynamic string), or an embedded
  small-int / shared object for common values.

The lite runtime exposes none of these. Apps that need them on web
or desktop have to wait for a future expansion of `libdazzle_lite`,
or run a Valkey sidecar and talk to it via TCP (which is what
[`Dazzle.NET`](../sdk/dotnet-quickstart.md) does).

## Persistence on mobile

Two complementary mechanisms inherited from Valkey:

### AOF — append-only file

Every write command is appended to `appendonly.aof`. On restart the
server replays the file. `appendfsync everysec` (default) flushes
once a second; `always` flushes per write but kills mobile latency
budget. Mobile defaults to `everysec` on a writable subdirectory of
the app's data dir.

### RDB — point-in-time snapshot

A binary serialisation of the entire keyspace. Triggered on
`save 60 1` (default) or manually via `BGSAVE`. Useful for
faster cold starts than full AOF replay on app launch.

Mobile apps that need to control persistence policy explicitly can
configure `DazzleConfig` to disable one or both, or to redirect
`dir` to a different location.

## Persistence on lite (web / desktop)

There is no AOF or RDB. The host application **explicitly calls**
`dazzle_save_snapshot` and writes the resulting blob wherever it
wants:

- **Flutter Web / RN Web / React DOM** — Origin Private File System
  (OPFS) via `navigator.storage.getDirectory()`. The bridge code in
  `dazzle_web.dart` / `dazzle_web.ts` manages a single binary file
  per `opfsFileName`.
- **Flutter Desktop** — a regular file on disk. Default location is
  `<cwd>/.dazzle/snapshot.bin`; consumers should override
  `snapshotPath:` with `path_provider.getApplicationSupportDirectory()`.
- **C++ server** — entirely up to the host. The smoke test writes
  to `dazzle_state.bin` next to the binary.

### Snapshot atomicity

The Flutter Desktop bridge writes via `<path>.tmp` then renames,
giving POSIX-atomic semantics on Linux/macOS and best-effort on
Windows. Web uses `FileSystemWritableFileStream.write()` +
`close()`, which OPFS implements as atomic per the spec.

If you need stronger guarantees (e.g. crash-consistent across
multiple snapshots) layer a write-ahead log on top of the
in-memory state and snapshot less frequently.

## RESP wire protocol

On mobile, command dispatch goes through Valkey's RESP3 (Redis
Serialisation Protocol) parser. The native SDK exposes
`dazzle_direct_command(argv)` which builds a multi-bulk request,
hands it to the server's command table, and parses the reply
back. The .NET SDK does the same over a TCP connection (since the
server isn't in-process there).

The lite runtime **does not implement RESP** — language bindings
call C functions directly. There's no encoder/decoder, no parser
layer, no need.

Apps that want a RESP-compatible interface on top of lite (e.g. to
replay traffic captured from a real Valkey server) would need to
write a thin RESP→C-API adapter. None ships today.

## What lives where — quick reference

| Data | Mobile | Lite | Lifetime |
|---|---|---|---|
| Hash KV | Valkey `dict.c` | `std::unordered_map` | Process |
| Vector index | hnswlib instance owned by the valkey-search module | hnswlib instance owned by `dazzle_wasm.cpp` | Process |
| AOF buffer | Valkey `aof.c` | — | Disk between sessions |
| RDB snapshot | Valkey `rdb.c` | — | Disk between sessions |
| `DZWS` snapshot | Same code path as lite | `dazzle_save_snapshot` | Wherever the host writes |
| Streams / SortedSets / Lists / Sets | Valkey native | — | Process + AOF/RDB |
