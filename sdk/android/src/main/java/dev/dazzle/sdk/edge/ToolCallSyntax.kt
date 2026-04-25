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

package dev.dazzle.sdk.edge

import dev.dazzle.sdk.ToolDeclaration

/**
 * Tool-call dialect used by a LiteRT-LM compatible model. On-device
 * fine-tunes do not share a wire format, so the adapter has to know
 * which one the model expects.
 *
 * - [gemma]: Gemma 2 / Gemma 3 / Gemma 4 instruction-tuned variants.
 *   Emits `<tool_call>{"name":"...","arguments":{...}}</tool_call>`.
 * - [llama32]: Llama 3.1 / 3.2 instruction-tuned variants. Emits
 *   `<|python_tag|>{"name":"...","parameters":{...}}<|eom_id|>`.
 * - [qwen25]: Qwen2.5 / Qwen3 instruction-tuned variants. Same XML
 *   delimiters as Gemma but the framing prompt lives under
 *   `# Tools` per the Qwen tool-use guide.
 * - [auto]: pick from the model filename at construction time.
 */
enum class ToolCallSyntax {
    auto,
    gemma,
    llama32,
    qwen25,
}

/**
 * Helpers for auto-detecting the syntax from a filename and for
 * rendering the tool declarations block that goes inside the system
 * prompt. Kept `internal` because callers should go through
 * [LiteRtLmClient] — the syntax parameter on the ctor is the public
 * entry point.
 */
internal object ToolCallPrompts {

    /**
     * Guess the dialect from the `.litertlm` filename. Falls back to
     * [ToolCallSyntax.gemma] (the default bundled model) when nothing
     * matches so tool-calling at least has a chance of working for a
     * consumer who ships an unknown variant.
     */
    fun detectFromFilename(name: String): ToolCallSyntax {
        val lc = name.lowercase()
        return when {
            "gemma" in lc  -> ToolCallSyntax.gemma
            "llama" in lc  -> ToolCallSyntax.llama32
            "qwen"  in lc  -> ToolCallSyntax.qwen25
            else           -> ToolCallSyntax.gemma
        }
    }

    /**
     * Render the `# Tools` section that the adapter appends to the
     * caller's system prompt. Empty string when [tools] is empty so
     * callers can unconditionally concatenate.
     */
    fun renderToolsSection(
        tools: List<ToolDeclaration>,
        syntax: ToolCallSyntax,
    ): String {
        if (tools.isEmpty()) return ""
        val resolved = if (syntax == ToolCallSyntax.auto) ToolCallSyntax.gemma else syntax
        return when (resolved) {
            ToolCallSyntax.gemma, ToolCallSyntax.qwen25 -> gemmaLikePrompt(tools)
            ToolCallSyntax.llama32 -> llamaPrompt(tools)
            ToolCallSyntax.auto    -> ""  // unreachable, the branch above resolves it
        }
    }

    // ── Dialect-specific prompt renderers ────────────────────────────────

    private fun gemmaLikePrompt(tools: List<ToolDeclaration>): String {
        val arr = tools.joinToString(",") { d ->
            """{"type":"function","function":{"name":"${esc(d.name)}",""" +
                """"description":"${esc(d.description)}",""" +
                """"parameters":${d.parameters.serialize()}}}"""
        }
        return """

# Tools
You have access to the following tools inside the <tools></tools> block:
<tools>
[$arr]
</tools>
For each function call respond with ONLY a JSON object wrapped in
<tool_call></tool_call> tags. Do not add any other text before or after.
Format:
<tool_call>{"name": "<function-name>", "arguments": {<arg-name>: <arg-value>, ...}}</tool_call>
"""
    }

    private fun llamaPrompt(tools: List<ToolDeclaration>): String {
        val arr = tools.joinToString(",") { d ->
            """{"name":"${esc(d.name)}","description":"${esc(d.description)}",""" +
                """"parameters":${d.parameters.serialize()}}"""
        }
        return """

# Tools
Here are the available functions:
[$arr]
When you need to call a function, respond with ONLY the call delimited
by the markers. Do not add any text before or after.
Format:
<|python_tag|>{"name": "<function-name>", "parameters": {<arg-name>: <arg-value>, ...}}<|eom_id|>
"""
    }

    private fun esc(s: String): String = buildString(s.length) {
        for (c in s) when (c) {
            '"'  -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> append(c)
        }
    }
}
