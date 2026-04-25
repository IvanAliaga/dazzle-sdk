// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package dev.dazzle.sdk

import java.io.File

/**
 * Valkey 8/9 modules that Dazzle knows how to enable at server start.
 *
 * Shipped modules are **statically linked** into `libdazzle.so` — loading
 * one does NOT dlopen a separate `.so` file at runtime. Instead the SDK
 * passes `--loadmodule @static:<name>` which Valkey's patched module
 * loader resolves via `dlopen(RTLD_DEFAULT)` + `dlsym` against a
 * per-module `ValkeyModule_OnLoad_<name>` symbol already in the process.
 * This keeps the APK layout to a single `.so`, sidesteps Android's
 * `extractNativeLibs` packaging quirk, and matches the iOS xcframework
 * architecture (everything linked into `libvalkey-server.a`).
 *
 * Requesting a module that's not shipped throws
 * [DazzleException.ModuleUnavailable]. The ROADMAP (`docs/ROADMAP.md`)
 * lists current and planned shipping status.
 *
 * Use [Custom] as an escape hatch for out-of-tree modules the SDK
 * doesn't know about — those DO resolve to a real file path on disk.
 */
sealed class DazzleModule {

    /** Pretty label used in log messages and error reports. */
    abstract val label: String

    /**
     * Argv token passed to `--loadmodule`. Either `@static:<name>` for a
     * module compiled into `libdazzle.so`, an absolute file path for a
     * [Custom] external module, or `null` when the module is core-integrated
     * (e.g. [Lua] in Valkey 9) and needs no `--loadmodule` flag.
     */
    internal abstract val staticModulePath: String?

    /**
     * Lua scripting: `EVAL`, `EVALSHA`, `SCRIPT LOAD`, `FUNCTION`.
     * Core-integrated in Valkey 9 — compiled into `libdazzle.so` directly
     * (no separate module), so no `--loadmodule` arg is needed.
     */
    data object Lua : DazzleModule() {
        override val label: String = "lua"
        override val staticModulePath: String? = null
    }

    /**
     * Vector similarity search (`valkey-search`). Unlocks `FT.CREATE`,
     * `FT.SEARCH`, `HSET` with `VECTOR` field types, and KNN queries for
     * semantic retrieval over embedded documents. Statically linked into
     * `libdazzle.so`.
     */
    data object VectorSearch : DazzleModule() {
        override val label: String = "vector-search"
        override val staticModulePath: String = "@static:vectorsearch"
    }

    /**
     * Time series (`valkey-ts`). Native `TS.ADD`, `TS.RANGE`, `TS.MRANGE`,
     * automatic downsampling, compaction rules.
     *
     * NOT shipped in the current arm64 build — requesting it throws.
     */
    data object TimeSeries : DazzleModule() {
        override val label: String = "time-series"
        override val staticModulePath: String = "@static:timeseries"
    }

    /**
     * JSON document type (`valkey-json`). `JSON.SET`, `JSON.GET`,
     * JSONPath queries.
     *
     * NOT shipped in the current arm64 build — requesting it throws.
     */
    data object Json : DazzleModule() {
        override val label: String = "json"
        override val staticModulePath: String = "@static:json"
    }

    /**
     * Probabilistic data structures (`valkey-bloom`). `BF.ADD`, `BF.EXISTS`,
     * `CF.ADD` (cuckoo filter), `TDIGEST.*`, `TOP-K`.
     *
     * NOT shipped in the current arm64 build — requesting it throws.
     */
    data object Bloom : DazzleModule() {
        override val label: String = "bloom"
        override val staticModulePath: String = "@static:bloom"
    }

    /**
     * Temporal Fault Intelligence (`dazzle-tfi`, Plan 19). Symbolic
     * online-learning fault predictor for LLM-augmented industrial
     * monitoring workloads. Unlocks `TFI.INIT` / `TFI.INGEST` /
     * `TFI.EVENT` / `TFI.SCORE` / `TFI.OBSERVE` / `TFI.EXPLAIN` /
     * `TFI.FEATURES` / `TFI.RESET`. Statically linked into `libdazzle.so`.
     *
     * This module is the Dazzle contribution that differentiates us from
     * upstream Valkey — no equivalent exists in Valkey 9.0 or
     * valkey-search.
     */
    data object TFI : DazzleModule() {
        override val label: String = "tfi"
        override val staticModulePath: String = "@static:tfi"
    }

    /**
     * Escape hatch: load an arbitrary Valkey module from a file path you
     * control. The library does no validation beyond the caller's
     * guarantee that the file exists — if the module fails to init,
     * Valkey aborts at start and the native log has the reason.
     */
    data class Custom(val file: File, override val label: String = file.name) : DazzleModule() {
        override val staticModulePath: String = file.absolutePath
    }

    /**
     * True when this module's OnLoad symbol is compiled into libdazzle.so
     * in the current build. [Custom] always counts as shipped — the caller
     * takes responsibility for the file. SDK updates that add or drop a
     * module only need to flip this flag.
     */
    internal val isShipped: Boolean
        get() = when (this) {
            Lua, VectorSearch, TFI -> true
            TimeSeries, Json, Bloom -> false
            is Custom -> true
        }
}
