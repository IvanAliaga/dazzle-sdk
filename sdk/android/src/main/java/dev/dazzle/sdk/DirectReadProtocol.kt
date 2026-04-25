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
 * Selects how [DazzleServer.directReadFields] and [HashKey.mGetDirect]
 * return data from the in-process snapshot cache.
 *
 * Both modes bypass the event-loop pipe (Phase 1 optimization) — the only
 * difference is whether the result goes through RESP serialisation.
 *
 * ## Choosing a mode
 *
 * Use **TYPED** if:
 * - You are writing new code with Dazzle
 * - You want the lowest possible retrieval latency (~50 µs total)
 * - You access field values directly as Kotlin strings
 *
 * Use **RESP** if:
 * - You have existing code that parses RESP2/RESP3 responses
 * - You are migrating a codebase that used Jedis / Lettuce / ioredis
 * - You need to inspect the raw protocol for debugging
 * - You want byte-for-byte compatibility with a standard HMGET response
 *
 * ## Performance comparison (Moto G35 5G, HMGET 6 fields)
 *
 * | Mode | Latency | Breakdown |
 * |------|---------|-----------|
 * | Pipe (no bypass) | ~948 µs | 2 kernel ctx-switch + mutex + pipe r/w |
 * | RESP (Phase 1)   | ~150 µs | snapshot rdlock + snprintf×6 + RESP parse |
 * | TYPED (Phase 5)  | ~50 µs  | snapshot rdlock + NewStringUTF×6 |
 *
 * ## Migration example
 *
 * ```kotlin
 * // Before (RESP path — compatible with any Redis client):
 * val config = DazzleConfig(directReadProtocol = DirectReadProtocol.RESP)
 * val raw: String = server.directRead("HMGET", "sensor:stats", "count", "temp_sum")
 * // raw = "*2\r\n$3\r\n200\r\n$6\r\n4481.0\r\n"
 * val values = RespParser.parse(raw).asArray().map { it.asBulkOrNull() }
 *
 * // After (TYPED path — no RESP, no parsing):
 * val config = DazzleConfig(directReadProtocol = DirectReadProtocol.TYPED)
 * val values: Array<String?> = server.directReadFields("sensor:stats", "count", "temp_sum")
 * //            values[0] = "200", values[1] = "4481.0"  (direct strings, no parsing)
 * ```
 */
enum class DirectReadProtocol {

    /**
     * **Typed (default)**: returns `String?[]` directly from the snapshot.
     *
     * No RESP encoding in C, no RESP decoding in Kotlin. The snapshot field
     * values are wrapped in `NewStringUTF()` calls and returned as a Java
     * `String[]`. Null elements indicate absent fields (same semantics as
     * RESP `$-1\r\n` nil bulk strings).
     *
     * Best for new code. Not compatible with tools that expect raw RESP bytes.
     */
    TYPED,

    /**
     * **RESP (compatibility mode)**: returns a RESP2-encoded bulk array string.
     *
     * The snapshot values are serialised into `*N\r\n$len\r\nval\r\n...` format
     * and returned as a single Kotlin String. The Kotlin layer decodes this with
     * `RespParser.parse(raw).asArray()` — identical to a live HMGET response from
     * a standard Valkey/Redis server over TCP.
     *
     * Use this when migrating existing Redis client code to Dazzle, or
     * when you need RESP3 parity for protocol compatibility testing.
     */
    RESP,
}
