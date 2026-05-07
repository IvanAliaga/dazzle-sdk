# Changelog

All notable changes to `Dazzle.NET`. This package follows the Dazzle
SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

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
