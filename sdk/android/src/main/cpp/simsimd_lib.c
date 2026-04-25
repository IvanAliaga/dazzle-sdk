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

// Android (arm64) — enable NEON, disable SVE (not universally available).
#if defined(__aarch64__)
#  define SIMSIMD_TARGET_NEON 1
#  define SIMSIMD_TARGET_SVE 0
#endif

#include "third_party/simsimd/c/lib.c"
