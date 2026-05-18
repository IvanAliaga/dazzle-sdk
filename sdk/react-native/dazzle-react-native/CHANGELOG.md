# Changelog

All notable changes to `dazzle-react-native`. This package follows
the Dazzle SDK release line; see the
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

### Inherited from the underlying native bindings

- All Android (`sdk/android`) and iOS (`sdk/ios`) fixes ship with
  this RN package: Kirin-pass-15 universal `n_batch = n_ctx`, iOS
  launch-watchdog dispatch fix, `DazzleServer.vectorIndex`
  `initialCapacity` param, and the G80/EMUI-10 freeze unblock.

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
