# Changelog

All notable changes to `Dazzle.NET`. This package follows the Dazzle
SDK release line; see the
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

### No .NET-side surface changes

- This beta.6 cycle was paper-side + Android/iOS native fixes;
  the .NET P/Invoke surface (`Dazzle.Native.LibDazzle`) is
  unchanged.

## 1.0.0-beta.5

### Added — first public release of the .NET binding

- **`Dazzle.NET` NuGet package** for ASP.NET Core 9. P/Invoke
  bindings to the Dazzle native library, packaged as a single NuGet
  with pre-built native binaries for `linux-x64`, `linux-arm64`,
  `osx-arm64` and `win-x64` under `runtimes/{rid}/native/`. The
  bundled MSBuild targets copy the right binary next to the
  consumer's output automatically — no host C++ toolchain required.
- **`IDazzleClient`** — async wrapper over the C ABI. Hash ops
  (`HashSetAsync` / `HashGetAsync` / `HashGetAllAsync`), vector
  index management (`CreateVectorIndexSq8Async`,
  `CreateVectorIndexFp16Async`), vector ops (`AddVectorAsync`,
  `AddVectorBatchAsync`, `SearchVectorAsync`), raw command exec, and
  `AUTH` on connect.
- **`AddDazzle()` DI extension** — single-call registration of
  `IDazzleClient` as a singleton in ASP.NET Core's
  `IServiceCollection`. Configure with `DazzleOptions` (Port,
  Password, vector dimension, HNSW M / efConstruction).
- **Symbol package** (`.snupkg`) shipped alongside for source-indexed
  debug symbols.

### Architecture note

This binding talks to a **Dazzle / Valkey server reachable over
TCP**. Unlike the iOS / Android SDKs that embed Valkey in-process,
the .NET target is for ASP.NET Core servers that already run a
Valkey or Dazzle sidecar (Docker, k8s).

If you need an *embedded* in-process surface from .NET — without a
Valkey sidecar — file an issue; the `libdazzle_lite` shared library
that powers Flutter Desktop and the C++ server SDK is a candidate,
just needs a P/Invoke wrapper.

### Sample

`samples/dotnet-vector-search/` — minimal ASP.NET Core 9 app that
seeds a small product catalog with mock embeddings and exposes
`POST /search`.
