# Cross-target ABI

How the same source compiles to seven distribution targets and why
the binary snapshot format round-trips byte-for-byte across all of
them.

## One source, three compile targets

The "lite" runtime — Hash KV + HNSW vector index + snapshot —
lives in **one C++ translation unit**:

```
core/web/src/dazzle_wasm.cpp      # ~370 lines, plain C++ + hnswlib
```

Three different toolchains consume it:

| Toolchain | Output | Where it lands |
|---|---|---|
| Emscripten (`emcc` from `core/web/build.sh`) | `dazzle.wasm` (236 KB) + `dazzle.js` (68 KB) | Shipped as static assets in `dazzle_flutter`, `dazzle-react-native`, `dazzle-react` |
| Native CMake (`core/native-lite/build.sh`) | `libdazzle_lite.{so,dylib,dll}` (~250 KB) | Bundled into `dazzle_flutter` (Linux/macOS/Windows desktop targets) and shipped standalone for C++ servers |
| Same TU also linked into the full Valkey embedded build | `libdazzle.{so,a}` / `Dazzle.xcframework` | Linked statically into the iOS / Android / Flutter mobile / RN mobile binaries, alongside Valkey 9.0.3 |

**Why one TU**: the alternative — separate WASM and native
implementations — would diverge on edge cases (NUL handling,
overflow checks, distance metric details). One TU compiled three
ways means a bug fixed once is fixed everywhere.

## C ABI surface

`extern "C"` declarations exposed by the lite runtime:

```c
// Hash KV
int dazzle_hset(const char *key, const char *field, const char *value);
const char *dazzle_hget(const char *key, const char *field);
int dazzle_hdel(const char *key, const char *field);
int dazzle_hexists(const char *key, const char *field);
const char *dazzle_hgetall(const char *key);
int dazzle_del(const char *key);

// Vector index — HNSW, L2 distance
int dazzle_vs_create(const char *name, int dim, int M, int ef_construction, int initial_cap);
int dazzle_vs_add(const char *name, const char *id, const float *embedding);
int dazzle_vs_search(const char *name, const float *query, int k, int ef,
                     float *out_dists, int max_out);
const char *dazzle_vs_search_ids(void);
int dazzle_vs_drop(const char *name);

// Snapshot
int dazzle_save_snapshot(uint8_t **out_buf, int *out_len);
int dazzle_load_snapshot(const uint8_t *buf, int len);
void dazzle_snapshot_release(void);

// Diagnostics
const char *dazzle_version(void);
int dazzle_clear(void);
```

Full canonical header at
[`core/native-lite/include/dazzle_lite.h`](../../core/native-lite/include/dazzle_lite.h).

### String marshalling

All string returns are **NUL-terminated UTF-8 owned by the library**,
valid only until the next `dazzle_*` call. Multi-record returns
(`dazzle_hgetall`, `dazzle_vs_search_ids`) use a NUL-separated
record stream:

```
"field1\0value1\0field2\0value2\0"
```

Each language binding has a small parser that splits on `\0`. The
buffer is a single contiguous allocation (no fragmentation across
calls) and gets freed/replaced on the next call.

### Vector buffers

Embeddings are passed as plain `float*` (host-endian, contiguous).
For WASM the host (Dart / TS) writes into the Emscripten heap via
`HEAPF32` views starting at `ptr / 4`. For native FFI the host
allocates with `calloc<Float>(N)` (Dart) or has the Float32 array
already in heap (C++).

## Language-binding map

How each target reaches the C ABI:

| Target | Mechanism | Source dir |
|---|---|---|
| Flutter Web / RN Web / React DOM | Emscripten `ccall` + heap views via `dart:js_interop` (Flutter) or TS-native interop | `sdk/{flutter,react-native,react}/.../src/web/` |
| Flutter Desktop | `dart:ffi` with `lookupFunction<C, D>(name)` for each export | `sdk/flutter/dazzle_flutter/lib/src/desktop/` |
| C++ server | Direct C linkage; consumer `#include "dazzle_lite.h"` and `-ldazzle_lite` | `sdk/cpp-server/` |
| .NET | `[LibraryImport]` (source-generated P/Invoke) over the full `libdazzle.so` (mobile-style build, not lite) | `sdk/dotnet/src/Native/LibDazzle.cs` |
| iOS Swift | Direct C interop via the `DazzleC` module map in the XCFramework | `sdk/ios/Sources/` |
| Android Kotlin | JNI through `valkeyjni.cpp` shim | `sdk/android/src/main/cpp/` |

## Snapshot binary format (`DZWS`)

The format is **identical across all lite-runtime targets**: a
snapshot saved by Flutter Web on Chrome can be loaded by a C++
server on Linux and produce bit-identical search results, provided
both link the same `libdazzle_lite` version.

```
[ 4 bytes ]  magic     = "DZWS"
[ 4 bytes ]  version   = 1                            (uint32 LE)

# Hash DB
[ 4 bytes ]  n_keys                                   (uint32 LE)
for each key:
  [ 4 ]  key_len                                      (uint32 LE)
  [ key_len ]  key                                    (UTF-8, no NUL)
  [ 4 ]  n_fields
  for each field:
    [ 4 ]  field_len
    [ field_len ]  field
    [ 4 ]  value_len
    [ value_len ]  value

# Vector indexes
[ 4 ]  n_indexes
for each index:
  [ 4 ]  name_len
  [ name_len ]  name
  [ 4 ]  dim
  [ 4 ]  hnsw_blob_len
  [ hnsw_blob_len ]  hnsw_blob       (hnswlib's saveIndex stream)
  [ 4 ]  n_id_pairs
  for each pair:
    [ 4 ]  id_len
    [ id_len ]  id
    [ 8 ]  label                                      (uint64 LE)
  [ 8 ]  next_label                                   (uint64 LE)
```

All multi-byte integers are **little-endian** (matches WASM and
every supported native platform without conversion).

The `hnsw_blob` is hnswlib v0.8.0's own `saveIndex` output. The
WASM build round-trips it through MEMFS (`/tmp/dazzle_*`) because
hnswlib v0.8.0 only exposes `loadIndex(path)` — see
[storage-layer.md](./storage-layer.md) for that workaround.

### Versioning

The first uint32 after the magic is the format version. Today only
version 1 exists. Future incompatible changes:

- Bump the version
- `dazzle_load_snapshot` returns `-3` on unknown versions
- Provide a separate migration tool, never auto-upgrade

Backward compatibility is a hard requirement: any snapshot that
loaded in version N must load in version N+1.

## Error codes

Negative return codes from `dazzle_load_snapshot`:

| Code | Reason |
|---|---|
| `-1` | Null input or buffer shorter than 8 bytes |
| `-2` | Bad magic (first 4 bytes ≠ `DZWS`) |
| `-3` | Unsupported version (today only `1` is accepted) |
| `-4` | Truncated payload — sub-record claims more bytes than remain |

Positive return: `1` on success.

## Threading guarantees by target

The C ABI itself is **single-threaded**. Concurrent calls into any
of the `dazzle_*` functions from different threads are undefined
behaviour. Each language binding wraps this differently:

- **WASM**: browser is single-threaded by default — concurrency
  needs SharedArrayBuffer + COOP/COEP headers, which the lite
  runtime does not opt into. Dart Isolates and Web Workers each
  load their own module instance.
- **Native (lite)**: callers must serialise. The Flutter Desktop
  bridge does this implicitly because Dart code on the platform
  thread is single-threaded.
- **Mobile (full Valkey)**: the embedded server has its own thread
  pool and locking; SDK calls go through a JNI/Swift queue that
  serialises hot-path commands. See [threading-model.md](./threading-model.md).

## Testing the ABI in CI

Two CI jobs gate ABI regressions:

- **`cpp-smoke`** (Linux only) — builds `sdk/cpp-server/test/smoke_test.cpp`
  against the freshly built `libdazzle_lite.so`, runs the binary,
  fails the release if any of the 19 round-trip checks fails.
- **`flutter-desktop-test`** (Linux + macOS) — runs the
  `test/desktop/dazzle_desktop_test.dart` suite against the matrix
  artefact, exercising every `dart:ffi` typedef.

Together they catch:

- Missing or renamed exports (linker fails)
- Type-signature drift (FFI typedef mismatch shows up in the Dart
  test as a runtime crash on first call)
- Snapshot format regressions (round-trip test asserts bit-equal)
