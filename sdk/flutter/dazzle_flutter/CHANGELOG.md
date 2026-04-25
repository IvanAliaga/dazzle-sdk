# Changelog

All notable changes to `dazzle_flutter`. This package follows the
Dazzle SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

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
