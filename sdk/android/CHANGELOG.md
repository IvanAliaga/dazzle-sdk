# Changelog

All notable changes to the Android (Kotlin / Gradle / Maven Central)
binding. This SDK follows the Dazzle release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

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
