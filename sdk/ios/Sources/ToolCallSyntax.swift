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

import Foundation

/// Tool-call dialect used by a LiteRT-LM compatible model. On-device
/// fine-tunes do not share a wire format, so the adapter has to know
/// which one the model expects.
///
/// - `gemma`: Gemma 2 / Gemma 3 / Gemma 4 instruction-tuned variants.
///   Emits `<tool_call>{"name":"...","arguments":{...}}</tool_call>`.
/// - `llama32`: Llama 3.1 / 3.2 instruction-tuned variants. Emits
///   `<|python_tag|>{"name":"...","parameters":{...}}<|eom_id|>`.
/// - `qwen25`: Qwen2.5 / Qwen3 instruction-tuned variants. Same XML
///   delimiters as Gemma with a Qwen-style framing prompt.
/// - `auto`: pick from the model filename at construction time.
public enum ToolCallSyntax: Sendable, Equatable {
    case auto
    case gemma
    case llama32
    case qwen25
}

/// Helpers for auto-detecting the syntax from a filename and for
/// rendering the tool declarations block that goes inside the system
/// prompt. Exposed as `public` so the opt-in `DazzleLiteRTLM` target
/// can consume them; most SDK users will go through `LiteRtLmClient`
/// and never touch these directly.
public enum ToolCallPrompts {

    /// Guess the dialect from the `.litertlm` filename. Falls back to
    /// `.gemma` (the default bundled model) when nothing matches so
    /// tool-calling at least has a chance of working for a consumer
    /// who ships an unknown variant.
    public static func detectFromFilename(_ name: String) -> ToolCallSyntax {
        let lc = name.lowercased()
        if lc.contains("gemma") { return .gemma }
        if lc.contains("llama") { return .llama32 }
        if lc.contains("qwen")  { return .qwen25 }
        return .gemma
    }

    /// Render the `# Tools` section that the adapter appends to the
    /// caller's system prompt. Empty string when `tools` is empty so
    /// callers can unconditionally concatenate.
    public static func renderToolsSection(
        _ tools: [ToolDeclaration],
        syntax: ToolCallSyntax
    ) -> String {
        guard !tools.isEmpty else { return "" }
        let resolved: ToolCallSyntax = (syntax == .auto) ? .gemma : syntax
        switch resolved {
        case .gemma, .qwen25:
            return gemmaLikePrompt(tools)
        case .llama32:
            return llamaPrompt(tools)
        case .auto:
            return ""   // unreachable — resolved above
        }
    }

    // MARK: – Dialect-specific prompt renderers

    private static func gemmaLikePrompt(_ tools: [ToolDeclaration]) -> String {
        let arr = tools.map { d in
            "{\"type\":\"function\",\"function\":{\"name\":\"\(esc(d.name))\"," +
            "\"description\":\"\(esc(d.description))\"," +
            "\"parameters\":\(d.parameters.serialize())}}"
        }.joined(separator: ",")
        return """

        # Tools
        You have access to the following tools inside the <tools></tools> block:
        <tools>
        [\(arr)]
        </tools>
        For each function call respond with ONLY a JSON object wrapped in
        <tool_call></tool_call> tags. Do not add any other text before or after.
        Format:
        <tool_call>{"name": "<function-name>", "arguments": {<arg-name>: <arg-value>, ...}}</tool_call>
        """
    }

    private static func llamaPrompt(_ tools: [ToolDeclaration]) -> String {
        let arr = tools.map { d in
            "{\"name\":\"\(esc(d.name))\",\"description\":\"\(esc(d.description))\"," +
            "\"parameters\":\(d.parameters.serialize())}"
        }.joined(separator: ",")
        return """

        # Tools
        Here are the available functions:
        [\(arr)]
        When you need to call a function, respond with ONLY the call delimited
        by the markers. Do not add any text before or after.
        Format:
        <|python_tag|>{"name": "<function-name>", "parameters": {<arg-name>: <arg-value>, ...}}<|eom_id|>
        """
    }

    private static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out
    }
}
