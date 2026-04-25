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
 * Typed representation of a Valkey / RESP reply.
 *
 * The library's low-level [DazzleServer.directCommand] path hands back a
 * raw RESP string (the same bytes Valkey wrote to the wire). The typed
 * primitives parse that string into a [RespValue] tree which is easier
 * to destructure without regex-level string munging.
 *
 * The five cases are the full RESP-2 vocabulary Valkey uses internally:
 * simple strings (`+OK`), errors (`-ERR ...`), integers (`:42`), bulk
 * strings (`$5\r\nhello\r\n` or `$-1\r\n` for null), and arrays
 * (`*2\r\n...` or `*-1\r\n` for null array).
 */
sealed class RespValue {
    /** `+<text>\r\n` — short status replies like "OK", "PONG". */
    data class SimpleString(val value: String) : RespValue()

    /** `-<text>\r\n` — error reply, e.g. `ERR wrong number of arguments`. */
    data class Error(val value: String) : RespValue()

    /** `:<n>\r\n` — signed 64-bit integer. */
    data class Integer(val value: Long) : RespValue()

    /** `$N\r\n<bytes>\r\n` or `$-1\r\n` (null bulk). */
    data class Bulk(val value: String?) : RespValue() {
        val isNull: Boolean get() = value == null
    }

    /** `*N\r\n<N nested values>` or `*-1\r\n` (null array). */
    data class Array(val items: List<RespValue>?) : RespValue() {
        val isNull: Boolean get() = items == null
        val size: Int get() = items?.size ?: 0
    }

    // ── Convenience accessors used by the primitive wrappers ──────────────

    /** Returns the bulk-string payload, or throws if this is not a Bulk. */
    fun asBulkOrNull(): String? = when (this) {
        is Bulk -> value
        is SimpleString -> value     // Valkey sometimes replies with +OK for writes
        is Integer -> value.toString()
        else -> null
    }

    /** Returns the integer payload, or null if this reply is not an integer. */
    fun asLongOrNull(): Long? = when (this) {
        is Integer -> value
        is Bulk -> value?.toLongOrNull()
        is SimpleString -> value.toLongOrNull()
        else -> null
    }

    /** Returns the array items, or empty list for null / non-array replies. */
    fun asArray(): List<RespValue> = (this as? Array)?.items ?: emptyList()

    /** Returns the error string if this is an Error reply, or null. */
    val errorOrNull: String? get() = (this as? Error)?.value
}

/**
 * Parser for a single RESP-2 reply.
 *
 * RESP bulk headers (`$<N>`) specify the payload length in **bytes** of
 * the UTF-8 wire representation. Our native layer returns the reply as a
 * Kotlin String via `NewStringUTF`, which decodes UTF-8 into UTF-16 code
 * units — so one multi-byte glyph (e.g. `°` = 2 bytes) becomes a single
 * Kotlin `Char`. Parsing the input as chars therefore drifts off the
 * header whenever a payload contains non-ASCII text.
 *
 * The parser re-encodes the input to UTF-8 `ByteArray` once up-front and
 * walks bytes, which is correct for any RESP-2 reply the Valkey pipe
 * produces. The overhead is one full-buffer UTF-16 → UTF-8 copy; for the
 * pipe fallback path (hit only on snapshot misses) this is dwarfed by
 * the pipe round-trip, and the TYPED fast path does not hit the parser.
 *
 * Binary-safe bulks (replies containing embedded null bytes) still
 * work because `NewStringUTF` passes nulls through as U+0000 which
 * re-encodes to 0x00 in the byte buffer.
 */
object RespParser {

    /** Parses the entire [raw] string as a single RESP reply. Throws
     *  [DazzleException.TransportError] if the input is malformed. */
    fun parse(raw: String): RespValue {
        val cursor = Cursor(raw.toByteArray(Charsets.UTF_8))
        return parseOne(cursor)
    }

    private class Cursor(val b: ByteArray, var pos: Int = 0) {
        val length: Int get() = b.size
        fun advance(): Byte = b[pos++]
        fun readLine(): String {
            val end = indexOfCrlf(pos)
            if (end < 0) throw DazzleException.TransportError(
                "malformed RESP: no CRLF at pos=$pos in reply of length ${b.size}"
            )
            val line = String(b, pos, end - pos, Charsets.UTF_8)
            pos = end + 2
            return line
        }
        fun readExact(n: Int): String {
            if (pos + n > b.size) throw DazzleException.TransportError(
                "malformed RESP: expected $n bytes at pos=$pos, only ${b.size - pos} available"
            )
            val out = String(b, pos, n, Charsets.UTF_8)
            pos += n
            // Skip trailing CRLF that follows every bulk payload
            if (pos + 2 <= b.size && b[pos] == '\r'.code.toByte() && b[pos + 1] == '\n'.code.toByte()) pos += 2
            return out
        }
        private fun indexOfCrlf(from: Int): Int {
            val end = b.size - 1
            var i = from
            while (i < end) {
                if (b[i] == '\r'.code.toByte() && b[i + 1] == '\n'.code.toByte()) return i
                i++
            }
            return -1
        }
    }

    private fun parseOne(c: Cursor): RespValue {
        if (c.pos >= c.length) {
            throw DazzleException.TransportError("empty RESP reply")
        }
        val marker = c.advance().toInt().toChar()
        return when (marker) {
            '+' -> RespValue.SimpleString(c.readLine())
            '-' -> RespValue.Error(c.readLine())
            ':' -> RespValue.Integer(
                c.readLine().toLongOrNull()
                    ?: throw DazzleException.TransportError("bad integer reply")
            )
            '$' -> {
                val len = c.readLine().toIntOrNull()
                    ?: throw DazzleException.TransportError("bad bulk length header")
                if (len == -1) RespValue.Bulk(null)
                else RespValue.Bulk(c.readExact(len))
            }
            '*' -> {
                val n = c.readLine().toIntOrNull()
                    ?: throw DazzleException.TransportError("bad array header")
                if (n == -1) RespValue.Array(null)
                else RespValue.Array(List(n) { parseOne(c) })
            }
            else -> throw DazzleException.TransportError(
                "unknown RESP type '$marker' at pos ${c.pos - 1}"
            )
        }
    }
}
