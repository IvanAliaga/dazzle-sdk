# Changelog

All notable changes to the iOS Swift Package Manager binding. This
SDK follows the Dazzle release line; see the
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

### Fixed (iOS-specific)

- **`dazzle_llama_new_context`**: set `n_batch = n_ctx` so RAG
  prompts up to the context size prefill in a single `llama_decode`
  call. Without this the iOS bench was killed within 1 s of the
  first +RAG query — same Kirin pass-15 pattern. Same one-line
  patch costs ~30 MB extra compute buffer at `n_ctx = 2048`,
  negligible vs. the model weights. Sidebar item 12 of §5.9.5.
- **iOS bench launch watchdog (`0x8BADF00D`)**: `RagE2EBench.run()`
  called inline from `init()` exhausts the 20-second iOS launch
  watchdog. Fix: dispatch on
  `DispatchQueue.global(qos: .userInitiated).async` so SwiftUI can
  schedule the placeholder body inside the watchdog window. Sidebar
  item 11 of §5.9.5.

### Added (iOS-specific)

- **`DazzleServer.vectorIndex(...)`** convenience method extended
  with `initialCapacity: Int = 0` (plus `m`, `efConstruction`) so
  Swift callers can pre-size like the Android Kotlin ctor. Without
  this, `addBatchDirect` aborts at element 1024 on a FLAT index
  when the workload exceeds the SDK default `INITIAL_CAP`. Sidebar
  item 13 of §5.9.5.
- **Initial Swift bench port `experiment/llm/ios/RagE2EBench.swift`**.
  Mirrors the Kotlin harness over the same `dazzle_llama_*` and
  `dazzle_vs_*` C entry points. Exercises the first non-Android
  row of paper Table 17.

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
