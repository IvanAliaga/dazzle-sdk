# Changelog

All notable changes to the iOS Swift Package Manager binding. This
SDK follows the Dazzle release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.5

### Fixed

- **`ToolCallParser` accepts stringified-JSON `arguments`.** Some
  fine-tuned models (Qwen 0.5B fine-tune, OpenAI tool-call style)
  emit `arguments` as a JSON-encoded string instead of an object:

  ```json
  "arguments": "{\"query\": \"...\"}"
  ```

  The previous parser only handled the object shape, so stringified
  payloads fell through the `extractJsonObject` guard and the whole
  call was emitted as a `.text` delta — silently swallowing the tool
  call. `emitCall` now tries `extractJsonObject` first, then falls
  back to `extractJsonString`; downstream `argsFromJson` decodes
  both shapes the same way.

- **`dazzle_llama` no longer aborts on long prompts.** llama.cpp
  aborts the entire process (SIGABRT inside `llama_decode`) when
  the prompt exceeds `n_batch`. The previous hardcoded 512-token
  batch crashed the app on a 590-token prompt — reproduced on
  iPhone 12 Pro / iOS 26.3. `dazzle_llama_new_context()` now pins
  `n_batch = n_ubatch = n_ctx`, so the context accepts any prompt
  that fits in the window in a single decode call. Memory footprint
  documented on the public `dazzle_llama.h` header so consumers
  across iOS / Android / Flutter / RN see the same guidance.

### Note — companion targets

This release also ships first-class **Web** (Flutter Web / RN Web /
React DOM via `dazzle.wasm`) and **Desktop** (Flutter Desktop / C++
servers via `libdazzle_lite`) — see the corresponding package
CHANGELOGs and the [repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md).
The iOS surface itself is unchanged from beta.4 except for the two
fixes above.

## 1.0.0-beta.4

- See the [repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md#100-beta4--2026-04-29)
  for the full beta.4 entry.
