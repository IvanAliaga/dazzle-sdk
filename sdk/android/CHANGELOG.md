# Changelog

All notable changes to the Android (Kotlin / Gradle / Maven Central)
binding. This SDK follows the Dazzle release line; see the
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

### Fixed (Android-specific)

- **`experiment/backends/android/cpp/llamacpp/llamacpp_jni.c`**:
  apply `n_batch = n_ctx` universally in the experiment-app JNI
  bridge. Mirrors the Kirin pass-15 fix that previously landed in
  `core/platform/dazzle_llama.cpp` only. Without this, long-prompt
  RAG queries (~570 tokens) on Cortex-A75 v8.2 / EMUI 10 devices
  silently freeze inside `llama_decode` at the first +RAG turn —
  same root cause as the Kirin v8.0 split-prefill abort, only the
  failure mode differs. Sidebar item 14 of §5.9.5.

### Added (Android-specific)

- **Two new instrumentation extras for `RagE2EBench`**:
  `-e small_llm_file <name>` and `-e large_llm_file <name>`
  (`RagE2EBenchPhases.cfgFromSysProps` +
  `RagE2EBenchTest.propagateExtras`). Swap the LLM GGUF per-run
  without an APK rebuild. Used by §5.9.6 to A/B Q4_K_M vs Q5_K_M;
  reusable for any future quant level (Q5_K_S, Q6_K, Q8_0, IQ4_XS)
  or alternate model family.

## 1.0.0-beta.5

### Fixed (cross-stack — applies to the AAR's bundled native libs)

- **`dazzle_llama` no longer aborts on long prompts.** llama.cpp
  aborts the entire process (SIGABRT inside `llama_decode`) when
  the prompt exceeds `n_batch`. The previous hardcoded 512-token
  batch crashed the app on a 590-token prompt — reproduced on
  iPhone 12 Pro / iOS 26.3 first, but the same code ships in the
  Android AAR.  `dazzle_llama_new_context()` now pins
  `n_batch = n_ubatch = n_ctx`, so the context accepts any prompt
  that fits in the window in a single decode call. Memory
  footprint documented on the public `dazzle_llama.h` header.

### Note — companion targets

This release also ships first-class **Web** (Flutter Web / RN Web /
React DOM via `dazzle.wasm`), **Desktop** (Flutter Desktop / C++
servers via `libdazzle_lite`) and **.NET** (`Dazzle.NET` NuGet for
ASP.NET Core 9). See the corresponding package CHANGELOGs and the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md).

The Android Kotlin surface itself is unchanged from beta.4 except
the bundled-native fix above.

## 1.0.0-beta.5 (Android-specific — multi-target ARMv8.2 build)

The major Android-side changes in beta.5 — runtime SoC dispatch,
post-link opcode rewriting for SIGILL emulation on FP16 chips,
simsimd dispatch, the `DazzleNativeLoader` runtime CPU detection —
landed in an earlier preview tagged
`release/1.0.0-beta.5-paper-arxiv-v1`. They're now part of the
mainline beta.5 release. See the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md#100-beta5)
for the full Android-specific section.

## 1.0.0-beta.4

- See the [repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md#100-beta4--2026-04-29)
  for the full beta.4 entry.
