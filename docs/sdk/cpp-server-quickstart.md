# C++ server quickstart (Linux / macOS / Windows)

`libdazzle_lite` is the lightweight in-process Dazzle runtime for
non-Flutter C++ apps. Same shared library that powers the Flutter
Desktop and Web (WASM) targets — Hash KV + HNSW vector search +
binary snapshot persistence, **no Valkey server, no TCP, no RESP**.

For apps that need the full Dazzle surface (Lists, Streams,
SortedSets, Lua, pub-sub) on the server, use the
[`Dazzle.NET`](./dotnet-quickstart.md) NuGet package — it wraps a
real Valkey server reachable over TCP.

Latest: **v1.0.0-beta.5**.

## Build the library

```bash
git clone https://github.com/IvanAliaga/dazzle-sdk
cd dazzle-sdk/core/native-lite
./build.sh
```

Produces:

| Platform | Output |
|---|---|
| Linux x64 / arm64 | `core/native-lite/build/libdazzle_lite.so` (+ `.so.0`, `.so.0.1.0` symlinks) |
| macOS arm64 / x64 | `core/native-lite/build/libdazzle_lite.dylib` |
| Windows x64 (MSYS2 / MSVC) | `core/native-lite/build/dazzle_lite.dll` |

The header lives at `core/native-lite/include/dazzle_lite.h`.

## Link

### CMake

```cmake
add_library(dazzle_lite SHARED IMPORTED)
set_target_properties(dazzle_lite PROPERTIES
    IMPORTED_LOCATION /path/to/libdazzle_lite.so
    INTERFACE_INCLUDE_DIRECTORIES /path/to/dazzle_lite/include
)
target_link_libraries(my_app PRIVATE dazzle_lite)
```

### Plain Make / GCC

```sh
# On Linux, place the source file BEFORE -l flags — the default linker
# (--as-needed) discards libraries it doesn't see referenced from
# earlier objects.
g++ -std=c++17 \
    -I /path/to/dazzle_lite/include \
    my_app.cpp \
    -L /path/to/dazzle_lite/lib -ldazzle_lite \
    -Wl,-rpath,/path/to/dazzle_lite/lib \
    -o my_app
```

## Hello world

```cpp
#include <cstdio>
#include <vector>
#include "dazzle_lite.h"

int main() {
    // Hash KV
    dazzle_hset("chat:1", "role", "user");
    dazzle_hset("chat:1", "text", "What's the weather in Lima?");
    printf("role = %s\n", dazzle_hget("chat:1", "role"));

    // Vector index
    dazzle_vs_create("catalog", /*dim=*/4, /*M=*/16, /*ef_construction=*/200, /*initial_cap=*/1000);

    std::vector<float> a{1.0f, 0.0f, 0.0f, 0.0f};
    std::vector<float> b{0.0f, 1.0f, 0.0f, 0.0f};
    dazzle_vs_add("catalog", "product-a", a.data());
    dazzle_vs_add("catalog", "product-b", b.data());

    std::vector<float> q{0.95f, 0.05f, 0.0f, 0.0f};
    std::vector<float> dists(2);
    int n = dazzle_vs_search("catalog", q.data(), /*k=*/2, /*ef=*/-1, dists.data(), 2);

    const char* ids = dazzle_vs_search_ids();   // NUL-separated stream
    printf("top-%d hits, first id = %s\n", n, ids);

    // Persist to disk (host owns the bytes; this is just an in-memory blob).
    uint8_t* blob = nullptr; int blob_len = 0;
    dazzle_save_snapshot(&blob, &blob_len);
    FILE* f = fopen("dazzle_state.bin", "wb");
    fwrite(blob, 1, blob_len, f);
    fclose(f);
    dazzle_snapshot_release();

    return 0;
}
```

## API surface

See [`core/native-lite/include/dazzle_lite.h`](../../core/native-lite/include/dazzle_lite.h)
for the canonical C ABI. Highlights:

| Group | Functions |
|---|---|
| Hash KV | `dazzle_hset` / `_hget` / `_hdel` / `_hexists` / `_hgetall` / `_del` |
| Vector | `dazzle_vs_create` / `_vs_add` / `_vs_search` / `_vs_search_ids` / `_vs_drop` |
| Snapshot | `dazzle_save_snapshot` / `_load_snapshot` / `_snapshot_release` |
| Diagnostics | `dazzle_version` / `dazzle_clear` |

## Threading

`libdazzle_lite` is **single-threaded**. Wrap concurrent access at
the caller side. (Multi-threaded HNSW + KV is part of the full
Valkey embedded build that ships in the iOS / Android targets —
there the underlying server handles its own locking.)

## Cross-target snapshot compatibility

The snapshot binary format (`DZWS` magic + version 1) is identical
between web (WASM) and desktop (native) builds. A snapshot saved by
a Flutter Web app can be loaded by a C++ server and vice-versa,
provided both link the same `libdazzle_lite` version.

## Smoke test

```bash
# After core/native-lite/build.sh completes:
c++ -std=c++17 \
    -I core/native-lite/include \
    sdk/cpp-server/test/smoke_test.cpp \
    -L core/native-lite/build -ldazzle_lite \
    -Wl,-rpath,$(pwd)/core/native-lite/build \
    -o /tmp/dazzle_smoke
/tmp/dazzle_smoke   # exit 0 = pass
```

## Reporting an issue

[https://github.com/IvanAliaga/dazzle-sdk/issues](https://github.com/IvanAliaga/dazzle-sdk/issues)
