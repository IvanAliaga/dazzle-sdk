# Dazzle — Technical documentation

Deep technical reference for SDK contributors and integrators who
need to reason about how the runtime works, not just how to call it.

For a high-level system overview see
[`docs/ARCHITECTURE.md`](../ARCHITECTURE.md). For per-stack
quickstarts (install + hello world) see
[`docs/sdk/README.md`](../sdk/README.md). For the API spec see
[`docs/sdk/API_CONTRACT.md`](../sdk/API_CONTRACT.md).

## Index

| Doc | What you'll find |
|---|---|
| [storage-layer.md](./storage-layer.md) | The primitives' on-disk and on-wire formats. RESP wire protocol, snapshot binary format (`DZWS`), HSET / sorted-set internals, AOF and RDB. |
| [vector-index.md](./vector-index.md) | HNSW algorithm implementation, parameter tradeoffs (`M`, `ef_construction`, `ef`), SQ8 quantisation, FP16 path on ARMv8.2, recall vs latency curves. |
| [cross-target-abi.md](./cross-target-abi.md) | How the same C++ TU compiles to WASM, native shared libs, and an iOS XCFramework. Snapshot binary compatibility. C ABI surface. P/Invoke / dart:ffi / js_interop wiring. |
| [threading-model.md](./threading-model.md) | Concurrency contract per target. Mobile (Valkey full): server thread + bio threads. Web/Desktop lite: single-threaded with caller-side serialisation. JNI / Swift / Dart hot-path rules. |
| [build-release-process.md](./build-release-process.md) | What CI builds when, how artefacts get from commit to NuGet/npm/pub.dev/Maven, the wasm-check gate, the SOVERSION pinning, the release checklist. |
| [performance.md](./performance.md) | Benchmark methodology, headline numbers (Moto G35 / iPhone 12 Pro), sources of speedup (post-link opcode rewriting, SIMSIMD dispatch, snapshot fast path). Pointers to the research paper. |
| [security.md](./security.md) | Authentication (AUTH on TCP), permissions for embedded modes, OPFS quota / origin isolation, supply-chain (signed releases, SHA-pinned actions). |

## Conventions used in this directory

- **"Mobile"** = iOS + Android, where the SDK embeds a full Valkey
  9.0.3 server in-process. The Flutter and React Native plugins are
  language bindings on top of these mobile binaries.
- **"Lite"** / **"Web/Desktop lite"** = the WASM build (Flutter Web,
  RN Web, React DOM) and the native shared library
  `libdazzle_lite` (Flutter Desktop, C++ servers). Same C++ TU,
  smaller surface (Hash + Vector + snapshot), no Valkey embedding.
- **".NET"** = ASP.NET Core 9 binding via P/Invoke to a Valkey or
  Dazzle server reachable over TCP. Not embedded; treats Valkey as
  a sidecar.

When a doc says "the runtime" without qualifier, assume Mobile.
When it says "Lite", the contract may differ.

## Out of scope here

- **API reference** (per-method docs) — that's [`docs/sdk/API_CONTRACT.md`](../sdk/API_CONTRACT.md).
- **How to use it from app code** — that's the per-stack quickstarts under [`docs/sdk/`](../sdk/).
- **Roadmap and planning** — that's [`docs/ROADMAP.md`](../ROADMAP.md).
- **Research paper** — that's `research/paper/`.

## When this doc is wrong

The code on the side the user is running is authoritative. These
docs are point-in-time descriptions; if you find a contradiction,
fix the doc OR fix the code (and reference an issue) — don't leave
both in the tree.
