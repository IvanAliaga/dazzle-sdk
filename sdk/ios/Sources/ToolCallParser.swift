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

/// Incremental parser that turns streaming text from a LiteRT-LM model
/// into `Delta` events, peeling out tool-call blocks from the
/// assistant's output and forwarding plain text verbatim.
///
/// ### Wire formats
///
/// - Gemma / Qwen2.5: `<tool_call>{"name":"...","arguments":{...}}</tool_call>`
/// - Llama 3.2:       `<|python_tag|>{"name":"...","parameters":{...}}<|eom_id|>`
///
/// Both dialects wrap a single JSON object between two ASCII
/// delimiters. The parser uses a simple two-state machine (text /
/// inside-call) and a rolling buffer so it can handle any chunk
/// boundary — including a delimiter split across two chunks.
///
/// ### Emission contract
///
/// The parser never emits a partial `.text` that straddles a potential
/// delimiter. Whenever the tail of the buffer *could* be the start of a
/// delimiter we hold it back until the next `process` / `flush` proves
/// it otherwise. This mirrors how OpenAI / Anthropic streaming servers
/// emit `content_block_delta` events: text out, tool call payload
/// separately.
public final class ToolCallParser {

    private let startDelim: String
    private let endDelim: String
    /// JSON field carrying the arguments dict — varies by dialect.
    private let argsField: String

    private var buf: String = ""
    private var insideCall: Bool = false
    /// Monotonic counter so each tool_call gets a unique id inside a
    /// stream.
    private var callSeq: Int = 0

    public init(syntax: ToolCallSyntax) {
        let resolved: ToolCallSyntax = (syntax == .auto) ? .gemma : syntax
        switch resolved {
        case .gemma, .qwen25:
            self.startDelim = "<tool_call>"
            self.endDelim   = "</tool_call>"
            self.argsField  = "arguments"
        case .llama32:
            self.startDelim = "<|python_tag|>"
            self.endDelim   = "<|eom_id|>"
            self.argsField  = "parameters"
        case .auto:
            preconditionFailure("unreachable — resolved above")
        }
    }

    /// Process the next chunk of raw model output. Returns zero or
    /// more deltas in emission order.
    public func process(_ chunk: String) -> [Delta] {
        var out: [Delta] = []
        buf.append(chunk)
        drain(into: &out, finalFlush: false)
        return out
    }

    /// Drain any remaining unemitted text. Call once when the
    /// underlying stream completes (before emitting `.end`).
    public func flush() -> [Delta] {
        var out: [Delta] = []
        drain(into: &out, finalFlush: true)
        return out
    }

    // MARK: – Private

    private func drain(into out: inout [Delta], finalFlush: Bool) {
        while true {
            if !insideCall {
                if let range = buf.range(of: startDelim) {
                    // Emit the text that precedes the marker verbatim.
                    let pre = String(buf[buf.startIndex..<range.lowerBound])
                    if !pre.isEmpty { out.append(.text(pre)) }
                    buf.removeSubrange(buf.startIndex..<range.upperBound)
                    insideCall = true
                    // fall through to the inside-call branch
                } else {
                    // No start marker. Emit everything EXCEPT the tail
                    // that might still match a start delimiter in a
                    // future chunk.
                    let hold = finalFlush ? 0 : max(0, startDelim.count - 1)
                    let safeLen = max(0, buf.count - hold)
                    if safeLen > 0 {
                        let idx = buf.index(buf.startIndex, offsetBy: safeLen)
                        let emit = String(buf[buf.startIndex..<idx])
                        if !emit.isEmpty { out.append(.text(emit)) }
                        buf.removeSubrange(buf.startIndex..<idx)
                    }
                    return
                }
            } else {
                if let range = buf.range(of: endDelim) {
                    let payload = String(buf[buf.startIndex..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    buf.removeSubrange(buf.startIndex..<range.upperBound)
                    insideCall = false
                    emitCall(payload: payload, into: &out)
                    // loop in case another tool_call follows in the
                    // same buffer
                } else {
                    if !finalFlush { return }
                    // Stream ended mid-call. Some fine-tuned models (e.g.
                    // our Qwen 2.5 LoRA) emit <|im_end|> directly after
                    // the balanced JSON without an explicit </tool_call>
                    // close tag. Try to recover by treating the buffer
                    // as the tool_call payload — if it parses cleanly we
                    // emit a real tool_call delta; otherwise fall back
                    // to surfacing the raw bytes as text.
                    let payload = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = Self.extractJsonString(payload, field: "name")
                    let args = Self.extractJsonObject(payload, field: argsField)
                    if name != nil && args != nil {
                        emitCall(payload: payload, into: &out)
                    } else if !buf.isEmpty {
                        out.append(.text(startDelim + buf))
                    }
                    buf.removeAll(keepingCapacity: false)
                    insideCall = false
                    return
                }
            }
        }
    }

    /// Parse the JSON payload and emit a `.toolCallStart` +
    /// `.toolCallArgs` pair. On malformed input, fall back to emitting
    /// the raw payload as a `.text` delta so the caller still sees the
    /// model's output instead of swallowing it.
    ///
    /// Accepts BOTH common shapes for the `arguments` field:
    ///   1. As a JSON object (Qwen 1.5B fine-tuned, Gemma):
    ///      `"arguments": {"query": "..."}`
    ///   2. As a stringified JSON (Qwen 0.5B fine-tuned, OpenAI style):
    ///      `"arguments": "{\"query\": \"...\"}"`
    /// In case (2) we extract the inner JSON string and emit it
    /// verbatim — the downstream tool's `argsFromJson` decodes the
    /// arguments the same way regardless of the wrapper.
    private func emitCall(payload: String, into out: inout [Delta]) {
        let name = Self.extractJsonString(payload, field: "name")
        guard let name else {
            out.append(.text(startDelim + payload + endDelim))
            return
        }
        let args: String? = Self.extractJsonObject(payload, field: argsField)
            ?? Self.extractJsonString(payload, field: argsField)
        guard let args else {
            out.append(.text(startDelim + payload + endDelim))
            return
        }
        callSeq += 1
        let id = "tc_\(callSeq)"
        out.append(.toolCallStart(id: id, name: name))
        out.append(.toolCallArgs(id: id, chunk: args))
    }

    // MARK: – Minimal JSON helpers
    //
    // We deliberately avoid pulling a JSON library here: this file
    // lives in the opt-in `DazzleLiteRTLM` target that consumers link
    // into their apps, so a JSON dependency would bloat every app that
    // ships its own LLMClient. Tool-call payloads are tiny and well-
    // formed (the model emits them verbatim from its template), so a
    // hand-rolled extractor is enough.

    /// Extract the value of a top-level string field. Nil if absent.
    private static func extractJsonString(_ json: String, field: String) -> String? {
        let key = "\"\(field)\""
        guard let keyRange = json.range(of: key) else { return nil }
        var idx = keyRange.upperBound
        let end = json.endIndex
        while idx < end, json[idx].isWhitespace { idx = json.index(after: idx) }
        guard idx < end, json[idx] == ":" else { return nil }
        idx = json.index(after: idx)
        while idx < end, json[idx].isWhitespace { idx = json.index(after: idx) }
        guard idx < end, json[idx] == "\"" else { return nil }
        idx = json.index(after: idx)
        var out = ""
        while idx < end {
            let c = json[idx]
            if c == "\\" {
                let next = json.index(after: idx)
                guard next < end else { return nil }
                let esc = json[next]
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n":  out.append("\n")
                case "r":  out.append("\r")
                case "t":  out.append("\t")
                default:   out.append(esc)
                }
                idx = json.index(after: next)
                continue
            }
            if c == "\"" { return out }
            out.append(c)
            idx = json.index(after: idx)
        }
        return nil
    }

    /// Extract the textual JSON of a top-level object field (including
    /// the surrounding braces). Nil if absent or malformed.
    private static func extractJsonObject(_ json: String, field: String) -> String? {
        let key = "\"\(field)\""
        guard let keyRange = json.range(of: key) else { return nil }
        var idx = keyRange.upperBound
        let end = json.endIndex
        while idx < end, json[idx].isWhitespace { idx = json.index(after: idx) }
        guard idx < end, json[idx] == ":" else { return nil }
        idx = json.index(after: idx)
        while idx < end, json[idx].isWhitespace { idx = json.index(after: idx) }
        guard idx < end, json[idx] == "{" else { return nil }
        let start = idx
        var depth = 0
        while idx < end {
            let c = json[idx]
            switch c {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let after = json.index(after: idx)
                    return String(json[start..<after])
                }
            case "\"":
                // skip string content so braces inside strings don't
                // confuse depth counting
                idx = json.index(after: idx)
                while idx < end {
                    let s = json[idx]
                    if s == "\\" {
                        let next = json.index(after: idx)
                        if next < end {
                            idx = json.index(after: next)
                            continue
                        }
                    }
                    if s == "\"" { break }
                    idx = json.index(after: idx)
                }
            default:
                break
            }
            if idx < end { idx = json.index(after: idx) }
        }
        return nil
    }
}
