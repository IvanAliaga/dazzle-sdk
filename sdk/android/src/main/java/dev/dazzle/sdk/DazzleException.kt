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
 * Typed error surface for Dazzle. Every failure the library can
 * report is a subclass of this — consumers can `catch` specific variants
 * instead of inspecting error strings.
 *
 * The library never returns a "silent null" for a real error; null is
 * reserved for semantic "key not found" / "field not present" cases. Any
 * other failure path throws a subclass of [DazzleException].
 */
sealed class DazzleException(message: String, cause: Throwable? = null) :
    RuntimeException(message, cause) {

    // ── Lifecycle ─────────────────────────────────────────────────────────

    /** `DazzleServer.start` failed before the server thread became ready
     *  (bad config, native init failure, missing module, etc.). */
    class StartFailed(message: String, cause: Throwable? = null) :
        DazzleException(message, cause)

    /** The configured port is in use and
     *  [DazzleConfig.allowPortFallback] is false. */
    class PortInUse(val port: Int) :
        DazzleException("port $port is in use and allowPortFallback=false")

    /** Every port in [DazzleConfig.portRange] is in use. */
    class NoFreePort(val range: IntRange) :
        DazzleException(
            "no free port in $range — pass a wider portRange or " +
                "tcpEnabled=false"
        )

    /** A [DazzleModule] was requested but its `.so` is not packaged in
     *  this build of Dazzle. */
    class ModuleUnavailable(val module: DazzleModule, val expectedAt: String) :
        DazzleException(
            "module '${module.label}' requires a native library that is " +
                "NOT shipped in this build of Dazzle. Expected it " +
                "at: $expectedAt. See docs/ROADMAP.md for the " +
                "module shipping plan."
        )

    // ── Command-level failures ────────────────────────────────────────────

    /** The server replied with a Valkey error string (`-ERR ...` on the
     *  wire). [reply] contains the message without the leading `-`. */
    class CommandFailed(val reply: String) :
        DazzleException("command failed: $reply")

    /** The command targeted a key whose type doesn't match (the classic
     *  `WRONGTYPE Operation against a key holding the wrong kind of value`
     *  error). */
    class WrongType(val key: String, val expected: String, val actual: String?) :
        DazzleException(
            "WRONGTYPE on key='$key' — expected $expected, " +
                "got ${actual ?: "unknown"}"
        )

    /** The server is out of memory and the command was rejected because
     *  the current `maxmemory-policy` does not allow evictions. */
    class OutOfMemory(message: String) : DazzleException(message)

    // ── Transport failures ────────────────────────────────────────────────

    /** A low-level transport error — the in-process pipe or TCP socket
     *  broke mid-command. The consumer can retry after reconnecting. */
    class TransportError(message: String, cause: Throwable? = null) :
        DazzleException(message, cause)

    /** A method that requires TCP (e.g. `command` multi-bulk parsing) was
     *  called on a server started with `tcpEnabled = false`. */
    class TcpDisabled(method: String) :
        DazzleException(
            "$method requires tcpEnabled=true — use directCommand instead " +
                "or rebuild the server with DazzleConfig(tcpEnabled = true)"
        )

    // ── Agent / LLM failures (Layer 2) ─────────────────────────────────────

    /** The assembled prompt (system + history + tools + user) exceeds the
     *  LLM's context window. Apply a [ContextWindow] or [CompactionPolicy]
     *  so older turns are dropped or summarized before dispatch. */
    class ContextOverflow(
        val tokensEstimated: Int,
        val tokensAllowed: Int,
    ) : DazzleException(
        "LLM context overflow: prompt ≈$tokensEstimated tokens, " +
            "model cap $tokensAllowed. Tighten ContextWindow or enable " +
            "CompactionPolicy on the Agent."
    )

    /** A tool call arrived from the model but its `arguments` JSON did
     *  not parse against the tool's argsSchema. The agent surfaces this
     *  as a `role=tool` response carrying the error so the model can
     *  self-correct on the next turn. */
    class ToolCallParseError(
        val toolName: String,
        val arguments: String,
        cause: Throwable? = null,
    ) : DazzleException(
        "tool call for '$toolName' had unparseable arguments: $arguments",
        cause,
    )

    /** An [LLMClient] failed to load its model weights / initialize the
     *  inference runtime. Wrapped at the adapter boundary so consumers
     *  don't have to depend on LiteRT-LM / llama.cpp types directly. */
    class ModelLoadFailed(val modelId: String, cause: Throwable? = null) :
        DazzleException("failed to load LLM model '$modelId'", cause)

    /** A [Tool.invoke] took longer than [ExecutionPolicy.commandTimeout]
     *  (or the agent's per-tool override). The calling coroutine has
     *  already been cancelled by the time this is thrown. */
    class ToolInvocationTimeout(
        val toolName: String,
        val timeoutMs: Long,
    ) : DazzleException(
        "tool '$toolName' did not complete within ${timeoutMs}ms — the " +
            "invoke() coroutine was cancelled. Consider raising the " +
            "timeout or moving slow work out-of-band."
    )

    /** The LLM emitted a tool_call referencing a name that was never
     *  registered with the agent. Usually indicates a prompt drift or
     *  model hallucination — log and surface as a `role=tool` error. */
    class UnknownTool(val toolName: String, val availableTools: List<String>) :
        DazzleException(
            "LLM requested tool '$toolName' but only these are registered: " +
                availableTools.joinToString(prefix = "[", postfix = "]")
        )
}
