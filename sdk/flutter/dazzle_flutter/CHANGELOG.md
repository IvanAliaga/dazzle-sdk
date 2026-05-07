# Changelog

All notable changes to `dazzle_flutter`. This package follows the
Dazzle SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.5

### Added — Flutter Web (WebAssembly runtime)

- `DazzleWeb`, `DazzleWebHash`, `DazzleWebVectorIndex` — exported
  from the package's main library. Backed by `dazzle.wasm` (~236 KB)
  built from the same C++ source as the native iOS / Android
  binaries. Same on-device promise extended to the browser:
  in-process HNSW vector search + hash KV, no remote server.
- Persistence via the Origin Private File System (OPFS).
  `DazzleWeb.persist()` writes a binary snapshot; `initialize()`
  restores it on boot. Multi-user isolation via `opfsFileName:`.
- Setup contract: add a `<script type="module">` tag to your app's
  `web/index.html` that imports
  `assets/packages/dazzle_flutter/web/native/dazzle.js` and assigns
  it to `globalThis.dazzleModule`. See the README "Flutter Web"
  section for the exact snippet.

### Added — Flutter Desktop (Linux / macOS / Windows)

- `DazzleDesktop`, `DazzleDesktopHash`, `DazzleDesktopVectorIndex` —
  same API surface as `DazzleWeb`, backed by `libdazzle_lite` via
  `dart:ffi`. Compiled from the same C++ source as the WASM build,
  so behaviour is byte-for-byte identical across web and desktop.
- Plugin declares `ffiPlugin: true` for `linux`, `macos`, `windows`
  — pre-built native libraries ship inside the package so consumers
  don't need a host C++ toolchain.
- Persistence to a regular file on disk (default
  `<cwd>/.dazzle/snapshot.bin`, override with `snapshotPath:`).
- Snapshot binary format identical to Web — a snapshot saved by a
  Flutter Web app loads byte-for-byte on Flutter Desktop.

### Fixed — iOS / Android (LLM stack)

- `ToolCallParser` now accepts `arguments` as a stringified JSON
  string (Qwen 0.5B fine-tune / OpenAI tool-call shape) in addition
  to the JSON-object shape (Gemma / Qwen 1.5B / Llama 3.x). The
  previous parser silently swallowed tool calls from models that
  emitted the OpenAI shape.
- `dazzle_llama_new_context()` pins `n_batch = n_ubatch = n_ctx` to
  prevent the SIGABRT inside `llama_decode` on prompts longer than
  the previous hardcoded 512-token batch. Reproduced on iPhone 12
  Pro / iOS 26.3 with a 590-token prompt.

### Scope (web / desktop)

- ✅ Hash KV + Vector index (HNSW) + binary snapshot persistence.
- ❌ Lists / Sets / SortedSets / Streams / standalone Strings — stay
  on iOS / Android mobile.
- ❌ On-device LLM clients (`LlamaCppClient`, `LiteRtLmClient`,
  `FoundationModelsClient`) — stay on iOS / Android mobile (these
  would need llama.cpp / LiteRT compiled to WASM, separate project).

## 1.0.0-beta.4

### Added

- First public pre-release. Embedded in-process database with HNSW
  vector search and a ChatAgent runtime for on-device LLM agents.
- Five swappable `LLMClient` adapters:
  - `LlamaCppClient` — GGUF inference, Isolate worker + `NativeCallable.listener`
    for zero-copy C→Dart token streaming.
  - `LiteRtLmClient` — Android-only plugin bridge to LiteRT-LM.
  - `FoundationModelsClient` — iOS 26+ Apple Intelligence bridge.
  - `OpenAICompatibleClient` — pure Dart + `package:http` with SSE.
  - `AnthropicClient` — Claude 3.5/4 family via the Messages API.
- Hot-path FFI calls for `HashKey.getAllDirect`,
  `SortedSetKey.rangeByScoreDirect`, `VectorIndex.searchDirect`;
  method channel reserved for lifecycle only.
- `ChatAgent.VectorRecallWindow` performs real on-device retrieval
  (HNSW_SQ8) and prepends top-k semantically similar older turns to
  the LastN window each `send()`.

### Notes

- Same `libdazzle.so` / `Dazzle.xcframework` as the native Android /
  iOS SDKs — zero behaviour drift across platforms.
- LiteRT-LM and Foundation Models adapters require platform-specific
  setup; see `README.md` and `samples/`.
