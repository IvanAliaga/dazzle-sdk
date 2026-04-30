// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0
//
// Standalone compilation unit for simsimd's dynamic-dispatch runtime, fetched
// from valkey-search/third_party/simsimd. On arm64 Android this auto-selects
// NEON kernels for dot/L2-squared on FLOAT32 vectors — the default hnswlib
// SpaceInterface falls back to scalar on ARM since hnswlib's SIMD path only
// covers x86 SSE/AVX/AVX512.
//
// Exposed entry points (declared by simsimd.h):
//   simsimd_dot_f32(a, b, n, &out)
//   simsimd_l2sq_f32(a, b, n, &out)

#define SIMSIMD_DYNAMIC_DISPATCH 1
#define SIMSIMD_NATIVE_F16 0
#define SIMSIMD_NATIVE_BF16 0

// Android (arm64) — enable basic NEON only. We deliberately do NOT
// enable SIMSIMD_TARGET_NEON_F16 / NEON_I8 / NEON_BF16 because, even
// though those kernels carry per-function `__attribute__((target("…")))`
// annotations that should re-target their own basic blocks, in practice
// the dispatcher's `ifunc` resolvers (and the linker's relocation step)
// can touch the high-target kernel addresses at load time on some
// devices, which SIGILLs Cortex-A73-class chips that lack asimdhp /
// asimddp (Kirin 659, Snapdragon 662). With only `SIMSIMD_TARGET_NEON`
// enabled, simsimd's dispatcher chooses among:
//   - `*_neon`    (fp32 NEON, universally available on arm64-v8a) → chosen on every chip
//   - `*_serial`  (portable scalar fallback for f16 / i8 paths)   → chosen on every chip
// The C++ distance functions in valkeysearch_module.cc call simsimd's
// dispatched entry points (`simsimd_dot_f32`, `simsimd_cos_i8`,
// `simsimd_dot_f16`), so the dispatcher does the right thing on every
// chip:
//   - fp32 path  →  `simsimd_dot_f32_neon`     (NEON, universal)
//   - i8   path  →  `simsimd_cos_i8_serial`    (scalar fallback)
//   - f16  path  →  `simsimd_dot_f16_serial`   (scalar fallback)
// Trade-off: on chips that DO have asimdhp/asimddp (Snapdragon 695,
// Kirin 710F, Snapdragon 8xx) the i8/f16 paths run at scalar speed
// instead of using SDOT/fp16 NEON. The performance hit is real but
// localized to SQ8/F16 latency on chips that anyway have the extension
// — fine for cross-platform correctness; a follow-up revision can
// re-enable the high-target kernels with proper guard against ifunc
// load-time touch (per-function `target_clones` + explicit dispatcher,
// not simsimd's auto-resolver).
// simsimd's dispatched entry points (`simsimd_cos_i8`, `simsimd_dot_f16`)
// reference the `*_neon` / `*_neon_dotprod` symbols at link time even
// when the corresponding SIMSIMD_TARGET_* macro is 0, so we must keep
// every TARGET enabled for the binary to link. The runtime dispatcher
// then picks the right kernel based on `simsimd_capabilities()`
// (reads /proc/cpuinfo); on Cortex-A73-class chips that lack
// asimdhp/asimddp the dispatcher should fall back to the serial path.
#if defined(__aarch64__)
#  define SIMSIMD_TARGET_NEON      1
#  define SIMSIMD_TARGET_NEON_F16  1
#  define SIMSIMD_TARGET_NEON_BF16 1
#  define SIMSIMD_TARGET_NEON_I8   1
#  define SIMSIMD_TARGET_SVE       0
#endif

#include "third_party/simsimd/c/lib.c"
