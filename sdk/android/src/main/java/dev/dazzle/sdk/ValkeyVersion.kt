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

/**
 * Selects which Valkey upstream version the native library is built against.
 *
 * The actual source is downloaded at build time via `FetchContent` in the
 * `sdk/android/src/main/cpp/CMakeLists.txt` (`GIT_TAG`) and patched with the
 * scripts under `versions/<version>/patches/`.
 *
 * This enum is a configuration knob for `DazzleConfig` — it does NOT change
 * the binary at runtime. Changing the selected version requires a rebuild.
 */
enum class ValkeyVersion(val tag: String) {
    V8("8.1.6"),
    V9("9.0.3");
}
