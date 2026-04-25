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

import Foundation

/// Selects how the app talks to the embedded Valkey server.
///
/// - `.inProcess` is the default for Dazzle — commands are dispatched
///   through the in-process pipe → SPSC ring buffer → io_uring pipeline
///   implemented in `core/transport/`. No TCP loopback, no kernel socket path.
///
/// - `.tcp(host:port:)` is a compatibility mode for parity tests against
///   stock Valkey over loopback. Production apps should not use it.
public enum Transport {
    case inProcess
    case tcp(host: String = "127.0.0.1", port: Int = 6379)
}
