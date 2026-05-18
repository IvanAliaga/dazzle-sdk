// Smoke test for libdazzle_lite — compiles to confirm:
//   1. The public header is self-contained
//   2. The shared library exports the expected ABI
//   3. Hash + Vector basic round-trips work
//
// Build (after `core/native-lite/build.sh`):
//
//   c++ -std=c++17 \
//     -I core/native-lite/include \
//     -L core/native-lite/build -ldazzle_lite \
//     -Wl,-rpath,$(pwd)/core/native-lite/build \
//     sdk/cpp-server/test/smoke_test.cpp -o smoke_test
//   ./smoke_test
//
// Exit 0 = pass, anything else = fail.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "dazzle_lite.h"

static int failed = 0;

#define CHECK(cond) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s (line %d)\n", #cond, __LINE__); failed++; } \
} while (0)

int main() {
    // --- Hash KV ---
    CHECK(dazzle_hset("k1", "f1", "v1") == 1);
    const char *got = dazzle_hget("k1", "f1");
    CHECK(got != nullptr);
    CHECK(strcmp(got, "v1") == 0);
    CHECK(dazzle_hexists("k1", "f1") == 1);
    CHECK(dazzle_hexists("k1", "missing") == 0);
    CHECK(dazzle_hdel("k1", "f1") == 1);
    CHECK(dazzle_hexists("k1", "f1") == 0);

    // --- Vector index ---
    CHECK(dazzle_vs_create("cat", 4, 16, 200, 100) == 1);
    CHECK(dazzle_vs_create("cat", 4, 16, 200, 100) == 0);   // idempotent

    std::vector<float> a{1.0f, 0.0f, 0.0f, 0.0f};
    std::vector<float> b{0.0f, 1.0f, 0.0f, 0.0f};
    std::vector<float> c{0.0f, 0.0f, 1.0f, 0.0f};
    CHECK(dazzle_vs_add("cat", "a", a.data()) == 1);
    CHECK(dazzle_vs_add("cat", "b", b.data()) == 1);
    CHECK(dazzle_vs_add("cat", "c", c.data()) == 1);

    std::vector<float> q{0.95f, 0.05f, 0.0f, 0.0f};
    std::vector<float> dists(2);
    int n = dazzle_vs_search("cat", q.data(), 2, -1, dists.data(), 2);
    CHECK(n == 2);

    const char *ids = dazzle_vs_search_ids();
    CHECK(ids != nullptr);
    // First id (NUL-separated stream) must be "a" — closest to the query.
    CHECK(strncmp(ids, "a", 1) == 0);
    CHECK(strlen(ids) >= 1 && ids[1] == '\0');     // "a\0" prefix

    // --- Snapshot ---
    uint8_t *blob = nullptr; int blob_len = 0;
    CHECK(dazzle_save_snapshot(&blob, &blob_len) == 1);
    CHECK(blob != nullptr);
    CHECK(blob_len > 8);
    CHECK(memcmp(blob, "DZWS", 4) == 0);

    // Round-trip: copy out, clear, reload, verify.
    std::vector<uint8_t> saved(blob, blob + blob_len);
    dazzle_snapshot_release();

    CHECK(dazzle_clear() == 1);
    CHECK(dazzle_hget("k1", "f1") == nullptr);     // wiped

    CHECK(dazzle_load_snapshot(saved.data(), (int)saved.size()) == 1);
    n = dazzle_vs_search("cat", q.data(), 1, -1, dists.data(), 1);
    CHECK(n == 1);
    CHECK(strncmp(dazzle_vs_search_ids(), "a", 1) == 0);

    // --- Diagnostics ---
    const char *ver = dazzle_version();
    CHECK(ver != nullptr);
    CHECK(strstr(ver, "dazzle-wasm") != nullptr);

    if (failed == 0) {
        printf("smoke_test: all checks passed\n");
        return 0;
    } else {
        fprintf(stderr, "smoke_test: %d check(s) FAILED\n", failed);
        return 1;
    }
}
