# Changelog

All notable changes to the C++ server target (`libdazzle_lite`).
This SDK follows the Dazzle release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.5

### Added — first public release of `libdazzle_lite`

- **Shared library** for non-Flutter C++ apps on Linux / macOS /
  Windows. Same C++ source as `dazzle.wasm` (Flutter Web / RN Web /
  React DOM), compiled natively. One CMake target in
  `core/native-lite/` produces:
  - `libdazzle_lite.so` (Linux x64 / arm64) with `SOVERSION 0`
  - `libdazzle_lite.dylib` (macOS arm64 / x64)
  - `dazzle_lite.dll` (Windows x64)
- **Public C ABI header** at `core/native-lite/include/dazzle_lite.h`.
  Functions:
  - Hash KV: `dazzle_hset` / `_hget` / `_hdel` / `_hexists` /
    `_hgetall` / `_del`.
  - Vector index (HNSW): `dazzle_vs_create` / `_vs_add` /
    `_vs_search` / `_vs_search_ids` / `_vs_drop`.
  - Snapshot: `dazzle_save_snapshot` / `_load_snapshot` /
    `_snapshot_release`.
  - Diagnostics: `dazzle_version` / `dazzle_clear`.
- **Smoke test** at `sdk/cpp-server/test/smoke_test.cpp` —
  end-to-end Hash + Vector + snapshot round-trip. Runs in CI on
  every release tag (linker + runtime check on Linux).

### Scope (vs the full Dazzle surface)

`libdazzle_lite` is intentionally a **subset** — it skips the full
Valkey embedding (networking, persistence subsystems, cluster, Lua,
pub-sub) and trades them for a smaller binary (~250 KB) that boots
instantly. For apps that need Lists / Streams / SortedSets / Lua
on the server, use the
[`Dazzle.NET`](https://www.nuget.org/packages/Dazzle.NET) NuGet
package which talks to a real Valkey sidecar over TCP.

### Snapshot interop

The binary snapshot format (`DZWS` magic + version 1) is identical
between the WASM build and the native `libdazzle_lite` build. A
snapshot saved by a Flutter Web app loads byte-for-byte on a C++
server linking the same `libdazzle_lite` version.

### Threading

Single-threaded. Wrap concurrent access at the caller side. The
multi-threaded surface ships in the iOS / Android targets where the
underlying full Valkey embedding handles its own locking.

### Build

```bash
cd core/native-lite
./build.sh
```

See [`README.md`](README.md) for link snippets (CMake, plain make).
