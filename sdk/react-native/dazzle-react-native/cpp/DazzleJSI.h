// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// JSI installer — pins `globalThis.__dazzle` to a HostObject that
// exposes sync zero-copy entry points for the hot loop
// (dazzleCommand + snap*). Same C symbols the Kotlin JNI / Swift
// cshim callers hit, just from inside the JS runtime.
//
// Each JS call now lands on a C function in ~1 µs — no bridge, no
// JSON. Compare to the RN synchronous bridge (~15 µs) and the RN
// async bridge (~100 µs). The TS shim (src/ffi/command.ts) prefers
// `globalThis.__dazzle` when it's there.

#pragma once

#include <jsi/jsi.h>

namespace dazzle {

/// Install the `__dazzle` binding on `rt`. Idempotent — calling
/// twice overwrites the previous HostObject.
void installJsi(facebook::jsi::Runtime& rt);

} // namespace dazzle
