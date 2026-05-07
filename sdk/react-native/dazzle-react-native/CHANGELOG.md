# Changelog

All notable changes to `dazzle-react-native`. This package follows
the Dazzle SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.5

### Added — React Native Web (WebAssembly runtime)

- New `dazzle-react-native/web` sub-module entry. `DazzleWeb`,
  `DazzleWebHash`, `DazzleWebVectorIndex` exposed from
  `import { DazzleWeb } from 'dazzle-react-native/web'`. Backed by
  `dazzle.wasm` (~236 KB) — same WebAssembly module the
  `dazzle_flutter` package and the standalone `dazzle-react`
  package use.
- Mobile bundles never load the WASM glue — the sub-path is opt-in,
  so iOS / Android binary size is unchanged.
- Persistence via the Origin Private File System (OPFS) with
  `DazzleWeb.persist()` / auto-restore in `initialize()`.
- Setup contract: serve `web/native/dazzle.{js,wasm}` as static
  assets via your bundler (Webpack / Metro web), and add a
  `<script type="module">` to your HTML entry that imports
  `dazzle.js` and assigns it to `globalThis.dazzleModule`. See the
  README "React Native Web" section for the exact snippet.

### Fixed — iOS / Android

- `ToolCallParser.swift` accepts `arguments` as a stringified JSON
  string (Qwen 0.5B fine-tune / OpenAI tool-call shape) in addition
  to the JSON-object shape — fixes silent tool-call swallowing on
  some fine-tunes.
- `dazzle_llama_new_context()` pins `n_batch = n_ubatch = n_ctx` so
  prompts longer than the previous hardcoded 512-token batch no
  longer crash the app with SIGABRT inside `llama_decode`.
  Reproduced on iPhone 12 Pro / iOS 26.3 with a 590-token prompt.

### Scope (RN Web)

- ✅ Hash KV + Vector index (HNSW) + binary snapshot persistence.
- ❌ Lists / Sets / SortedSets / Streams / standalone Strings — stay
  on iOS / Android mobile.
- ❌ On-device LLM clients — stay on iOS / Android mobile.

For pure React (DOM, no React Native) apps, see the new
[`dazzle-react`](https://www.npmjs.com/package/dazzle-react)
package which exposes idiomatic React hooks over the same WASM
runtime.

## 1.0.0-beta.4

### Added

- First public pre-release. Embedded in-process database with HNSW
  vector search and a ChatAgent runtime for on-device LLM agents.
- Five swappable `LLMClient` adapters:
  - `LlamaCppClient` — GGUF inference via `dazzleStartLlamaStream`
    native module, token events on `dazzle.llama.tokens`.
  - `LiteRtLmClient` — Android-only bridge to LiteRT-LM.
  - `FoundationModelsClient` — iOS 26+ Apple Intelligence bridge.
  - `OpenAICompatibleClient` — TypeScript + `fetch` with SSE
    streaming.
  - `AnthropicClient` — Claude 3.5/4 family via the Messages API.
- Hot-path sync bridges — `dazzleCommandSync`, `snapHGetAllSync`,
  `snapZRangeByScoreSync`, `snapSMembersSync`, `snapGetSync` —
  on both Android (Kotlin) and iOS (ObjC++/Swift).
- `ChatAgent.VectorRecallWindow` performs real on-device retrieval
  (HNSW_SQ8) and prepends top-k semantically similar older turns to
  the LastN window on every `send()`.

### Notes

- Same `libdazzle.so` / `Dazzle.xcframework` as the native Android /
  iOS SDKs — zero behaviour drift across platforms.
- LiteRT-LM and Foundation Models adapters require platform-specific
  setup; see `README.md` and the bundled samples.
