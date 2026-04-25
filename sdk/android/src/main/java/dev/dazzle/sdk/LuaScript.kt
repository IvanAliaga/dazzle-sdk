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
 * High-level Lua scripting handle. Obtain via `valkey.script(source)`.
 *
 * Lua scripts in Valkey are the canonical way to run a sequence of
 * commands atomically against server-side state. They are cached by
 * SHA1 of the source so the second [eval] call only sends the hash
 * instead of the whole source.
 *
 * ```kotlin
 * // Increment a counter only if it is currently under a cap.
 * val capIncrement = valkey.script("""
 *     local cur = redis.call('HGET', KEYS[1], ARGV[1])
 *     if cur == false then cur = '0' end
 *     if tonumber(cur) < tonumber(ARGV[2]) then
 *         return redis.call('HINCRBY', KEYS[1], ARGV[1], 1)
 *     else
 *         return -1
 *     end
 * """)
 *
 * val newValue = capIncrement.eval(
 *     keys = listOf("sensor:stats"),
 *     args = listOf("count", "10000"),
 * ).asLongOrNull() ?: -1L
 * ```
 *
 * For the edge-agent use case, Lua scripts let you express "atomic
 * read-decide-write" cycles (rate limiters, bounded counters,
 * conditional state updates) without MULTI/EXEC ceremony.
 */
class LuaScript internal constructor(
    val source: String,
    private val server: DazzleServer,
) {
    private var sha1: String? = null

    /**
     * EVAL source numkeys key... arg... — runs the script and returns
     * whatever reply it produced. On the first call the server caches
     * the script by SHA1, and subsequent calls use [evalSha] under the
     * hood for lower bandwidth.
     */
    fun eval(keys: List<String> = emptyList(), args: List<String> = emptyList()): RespValue {
        val cached = sha1
        if (cached != null) {
            val cmd = buildEvalShaArgs(cached, keys, args)
            val r = try { server.commandTyped(*cmd) } catch (_: DazzleException.CommandFailed) { null }
            if (r != null) return r
            // NOSCRIPT fallback — fall through to full EVAL + re-cache
        }
        val full = buildEvalArgs(keys, args)
        val reply = server.commandTyped(*full)
        if (sha1 == null) sha1 = loadSha()
        return reply
    }

    /**
     * EVALSHA sha numkeys key... arg... — sends only the SHA. Fails with
     * `NOSCRIPT` if the server never saw this source, in which case
     * [eval] handles the retry transparently.
     */
    fun evalSha(keys: List<String> = emptyList(), args: List<String> = emptyList()): RespValue {
        val cached = sha1 ?: loadSha().also { sha1 = it }
        val cmd = buildEvalShaArgs(cached, keys, args)
        return server.commandTyped(*cmd)
    }

    /** SCRIPT LOAD source — upload without running. Caches the SHA on this handle. */
    fun load(): String {
        val r = server.commandTyped("SCRIPT", "LOAD", source).asBulkOrNull()
            ?: throw DazzleException.TransportError("SCRIPT LOAD returned unexpected reply")
        sha1 = r
        return r
    }

    private fun loadSha(): String = load()

    private fun buildEvalArgs(keys: List<String>, args: List<String>): Array<String> {
        val out = mutableListOf("EVAL", source, keys.size.toString())
        out.addAll(keys)
        out.addAll(args)
        return out.toTypedArray()
    }

    private fun buildEvalShaArgs(sha: String, keys: List<String>, args: List<String>): Array<String> {
        val out = mutableListOf("EVALSHA", sha, keys.size.toString())
        out.addAll(keys)
        out.addAll(args)
        return out.toTypedArray()
    }
}
