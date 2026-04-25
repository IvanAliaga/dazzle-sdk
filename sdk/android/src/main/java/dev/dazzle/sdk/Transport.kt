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
 * Selects how the app talks to the embedded Valkey server.
 *
 * - `InProcess` is the default for Dazzle — commands are dispatched
 *   through the in-process pipe → SPSC ring buffer → io_uring pipeline
 *   implemented in `core/transport/`. No TCP loopback, no kernel socket path.
 *
 * - `Tcp` is a compatibility mode intended for parity tests against stock
 *   Valkey over loopback. It exists so benchmarks can compare against the
 *   upstream transport without swapping the entire library. Production apps
 *   should not use it.
 */
sealed class Transport {
    /** In-process dispatch via pipe / SPSC ring / io_uring (auto-selected at runtime). */
    object InProcess : Transport()

    /** Classic TCP loopback, for upstream-parity benchmarks only. */
    data class Tcp(val host: String = "127.0.0.1", val port: Int = 6379) : Transport()
}
