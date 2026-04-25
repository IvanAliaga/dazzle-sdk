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
 * Type-safe wrapper around a Valkey bitmap. Obtain via `valkey.bitmap("key")`.
 *
 * A Valkey "bitmap" is just a string interpreted as an array of bits. Useful
 * for compact presence tracking (did user X visit today?) and cardinality
 * counting with BITCOUNT. Each bit at offset [i] can be set or read
 * independently, and bitwise operations between bitmaps (AND, OR, XOR, NOT)
 * produce new bitmaps.
 *
 * ```kotlin
 * val visited = valkey.bitmap("visited:2026-04-15")
 *
 * visited.setBit(42, true)          // user 42 visited
 * visited.setBit(101, true)         // user 101 visited
 * val u42 = visited.getBit(42)      // true
 * val n   = visited.count()         // total bits set
 * ```
 */
class BitmapKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {

    /** SETBIT key offset value — returns the PREVIOUS bit at that offset. */
    @Suppress("FunctionName")
    fun setBit(offset: Long, bit: Boolean): Boolean {
        val v = if (bit) "1" else "0"
        val prev = server.commandTyped("SETBIT", key, offset.toString(), v).asLongOrNull() ?: 0L
        return prev == 1L
    }

    /** GETBIT key offset — reads a single bit. */
    fun getBit(offset: Long): Boolean =
        (server.commandTyped("GETBIT", key, offset.toString()).asLongOrNull() ?: 0L) == 1L

    /** BITCOUNT key [start end [BYTE|BIT]] — number of 1-bits in the range. */
    fun count(start: Long? = null, end: Long? = null): Long {
        val args = mutableListOf("BITCOUNT", key)
        if (start != null && end != null) {
            args += start.toString()
            args += end.toString()
        }
        return server.commandTyped(*args.toTypedArray()).asLongOrNull() ?: 0L
    }

    /**
     * BITPOS key bit [start [end [BYTE|BIT]]] — position of the first bit
     * matching [bit]. Returns -1 if not found.
     */
    fun firstPosition(bit: Boolean): Long {
        val b = if (bit) "1" else "0"
        return server.commandTyped("BITPOS", key, b).asLongOrNull() ?: -1L
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}
