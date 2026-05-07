# Dazzle Lite for C++ servers (Linux / macOS / Windows)

Lightweight in-process Dazzle runtime for C++ server apps. Same
`libdazzle_lite` shared library that the Flutter Desktop and Web
WASM targets build from — Hash KV + HNSW vector search + binary
snapshot persistence, no Valkey server, no TCP, no RESP.

For apps that need the full Dazzle surface (Lists, Streams,
SortedSets, Lua, pub-sub) on the server, use the **`Dazzle.NET`**
NuGet package — it wraps a real Valkey server reachable over TCP.

## Build

```bash
cd core/native-lite
./build.sh
```

Produces:

| Platform | Output |
|---|---|
| Linux x64/arm64 | `core/native-lite/build/libdazzle_lite.so` |
| macOS arm64/x64 | `core/native-lite/build/libdazzle_lite.dylib` |
| Windows x64 (MSYS2) | `core/native-lite/build/dazzle_lite.dll` |

The header lives at `core/native-lite/include/dazzle_lite.h`.

## Link

`pkg-config` and CMake configs are intentionally not generated — the
API is small enough that direct linkage is the right call:

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
# behaviour (--as-needed) discards libraries it doesn't see referenced
# from earlier objects.
g++ -std=c++17 \
    -I /path/to/dazzle_lite/include \
    my_app.cpp \
    -L /path/to/dazzle_lite/lib -ldazzle_lite \
    -Wl,-rpath,/path/to/dazzle_lite/lib \
    -o my_app
```

## Quickstart

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

    std::vector<float> a = {1.0f, 0.0f, 0.0f, 0.0f};
    std::vector<float> b = {0.0f, 1.0f, 0.0f, 0.0f};
    dazzle_vs_add("catalog", "product-a", a.data());
    dazzle_vs_add("catalog", "product-b", b.data());

    std::vector<float> q = {0.95f, 0.05f, 0.0f, 0.0f};
    std::vector<float> dists(2);
    int n = dazzle_vs_search("catalog", q.data(), /*k=*/2, /*ef=*/-1, dists.data(), 2);

    const char* ids = dazzle_vs_search_ids();   // NUL-separated stream
    printf("top-%d hits, first id length = %zu\n", n, std::strlen(ids));

    // Persist to disk (host owns the bytes; this is just an in-memory blob).
    uint8_t* blob; int blob_len;
    dazzle_save_snapshot(&blob, &blob_len);
    FILE* f = fopen("dazzle_state.bin", "wb");
    fwrite(blob, 1, blob_len, f);
    fclose(f);
    dazzle_snapshot_release();

    return 0;
}
```

## Threading

`libdazzle_lite` is **single-threaded**. Wrap concurrent access at the
caller side. (Multi-threaded HNSW + KV is part of the full Valkey
embedded build that ships in the iOS / Android / .NET targets — there
the underlying server handles its own locking.)

## Storage format

The snapshot binary format (`DZWS` magic + version 1) is identical
between web (WASM) and desktop (native) builds. A snapshot saved by
a Flutter Web app can be loaded by a C++ server and vice versa,
provided both link the same dazzle_lite version.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for per-version notes, or the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## License

Apache 2.0.
