# Changelog

All notable changes to `dazzle-react-native`. This package follows
the Dazzle SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

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
