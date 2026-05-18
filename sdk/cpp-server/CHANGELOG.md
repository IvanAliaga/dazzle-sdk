# Changelog

All notable changes to the C++ server target (`libdazzle_lite`).
This SDK follows the Dazzle release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.6 — 2026-05-12

### Paper-side updates (applies to every binding — the SDK runs the same harness everywhere)

- **§5.9.5 cross-platform extension.** End-to-end RAG reproduction
  now spans **5 physical mobile SoCs across 2 operating systems**:
  Unisoc T760 / Cortex-A76 (Moto G35 5G, Android 14), QCOM SD662 /
  Cortex-A73 (Moto G30, Android 11), HiSilicon Kirin 659 / Cortex-A53
  (Huawei P20 Lite, Android 9 / EMUI 9), MediaTek Helio G80 /
  Cortex-A75 (Huawei Y9a / FRL-L23, Android 10 / EMUI 10), and Apple
  A14 / Firestorm (iPhone 12 Pro, iOS 26). Four Android microarchitecture
  generations plus Apple Firestorm. Bootstrap CIs (B=10000, paired-qid
  resampling) star-mark every F1_short ratio at 95% confidence across
  the spread.
- **§5.9.6 quantization sensitivity sweep.** Q4_K_M vs Q5_K_M on the
  two v8.2 HNSW chips (Moto G35 5G + Huawei Y9a). Headline: the
  `em_contains` metric is flat between quant levels (deltas ≤ 0.025
  on every cell, inside the per-cell CI half-width). Latency reveals
  a bandwidth-vs-compute split — the faster A76 chip pays a +50%
  wall-clock tax for Q5, the slower A75 chip pays ≤+13% because it
  was already bandwidth-bound on Q4 weights. Disk footprint cost is
  +6.3% on the 0.5B GGUF and +15% on the 1.5B GGUF.
- **REPRODUCIBILITY §4a + §4b.** New recipes: per-device chunked
  instrumentation for §5.9.5 (any new chip can be added with a small
  set of `am instrument` invocations) and GGUF-swap for §5.9.6 (no
  rebuild needed to A/B Q4 vs Q5 vs future quant variants).
- **PDFs regenerated.** `research/paper/arxiv-build/paper.pdf` and
  `paper_es.pdf` rebuilt from the updated paper sources.

### No C++ server-side surface changes

- This beta.6 cycle was paper-side + Android/iOS native fixes;
  the `libdazzle_lite` shared-library surface for C++ servers is
  unchanged.

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
