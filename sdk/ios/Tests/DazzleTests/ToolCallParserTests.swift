// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

/// Pure-unit tests for the tool-call parser. Exercises the three
/// mainstream on-device dialects plus a handful of chunk-boundary
/// edge cases. Does not touch DazzleServer / LiteRT-LM so it runs
/// without the xcframework loaded.
final class ToolCallParserTests: XCTestCase {

    // MARK: – detectFromFilename

    func testDetectsGemmaFromFilename() {
        XCTAssertEqual(
            ToolCallPrompts.detectFromFilename("gemma-4-E2B-it.litertlm"),
            .gemma
        )
    }

    func testDetectsLlamaFromFilename() {
        XCTAssertEqual(
            ToolCallPrompts.detectFromFilename("llama-3.2-3b-instruct.litertlm"),
            .llama32
        )
    }

    func testDetectsQwenFromFilename() {
        XCTAssertEqual(
            ToolCallPrompts.detectFromFilename("qwen-2.5-1.5b-instruct.litertlm"),
            .qwen25
        )
    }

    func testDefaultsToGemmaForUnknownFilename() {
        XCTAssertEqual(
            ToolCallPrompts.detectFromFilename("phi3-mini.litertlm"),
            .gemma
        )
    }

    // MARK: – Gemma dialect

    func testParsesGemmaToolCallInOneChunk() {
        let parser = ToolCallParser(syntax: .gemma)
        let stream = """
        I'll look that up.
        <tool_call>{"name":"weather.get","arguments":{"city":"Lima"}}</tool_call>
        """
        let deltas = parser.process(stream) + parser.flush()

        var texts: [String] = []
        var calls: [(String, String, String)] = []   // id, name, argsJson
        for d in deltas {
            switch d {
            case .text(let t):
                texts.append(t)
            case .toolCallStart(let id, let name):
                calls.append((id, name, ""))
            case .toolCallArgs(let id, let chunk):
                if let idx = calls.firstIndex(where: { $0.0 == id }) {
                    calls[idx].2 += chunk
                }
            case .end:
                break
            }
        }
        XCTAssertEqual(texts.joined(), "I'll look that up.\n")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1, "weather.get")
        XCTAssertEqual(calls.first?.2, "{\"city\":\"Lima\"}")
    }

    func testParsesGemmaToolCallAcrossChunkBoundary() {
        let parser = ToolCallParser(syntax: .gemma)
        // Split the start delimiter in half: "<tool_" | "call>..."
        var deltas: [Delta] = []
        deltas += parser.process("leading text <tool_")
        deltas += parser.process("call>{\"name\":\"a\",\"arguments\":{}}</tool_call> trailing")
        deltas += parser.flush()

        var texts: [String] = []
        var names: [String] = []
        var args:  [String] = []
        for d in deltas {
            switch d {
            case .text(let t):          texts.append(t)
            case .toolCallStart(_, let n):    names.append(n)
            case .toolCallArgs(_, let c):     args.append(c)
            case .end:                  break
            }
        }
        XCTAssertEqual(texts.joined(), "leading text  trailing")
        XCTAssertEqual(names, ["a"])
        XCTAssertEqual(args,  ["{}"])
    }

    // MARK: – Llama dialect

    func testParsesLlamaToolCall() {
        let parser = ToolCallParser(syntax: .llama32)
        let stream = "<|python_tag|>{\"name\":\"search\",\"parameters\":{\"q\":\"hi\"}}<|eom_id|>"
        let deltas = parser.process(stream) + parser.flush()

        var names: [String] = []
        var args:  [String] = []
        for d in deltas {
            switch d {
            case .toolCallStart(_, let n): names.append(n)
            case .toolCallArgs(_, let c):  args.append(c)
            default: break
            }
        }
        XCTAssertEqual(names, ["search"])
        XCTAssertEqual(args,  ["{\"q\":\"hi\"}"])
    }

    // MARK: – Qwen dialect (same delimiters as Gemma)

    func testParsesQwenToolCall() {
        let parser = ToolCallParser(syntax: .qwen25)
        let stream = "<tool_call>{\"name\":\"q_fn\",\"arguments\":{\"n\":1}}</tool_call>"
        let deltas = parser.process(stream) + parser.flush()
        var names: [String] = []
        for d in deltas {
            if case .toolCallStart(_, let name) = d { names.append(name) }
        }
        XCTAssertEqual(names, ["q_fn"])
    }

    // MARK: – Edge cases

    func testMultipleToolCallsInOneStream() {
        let parser = ToolCallParser(syntax: .gemma)
        let stream = """
        <tool_call>{"name":"a","arguments":{}}</tool_call>
        middle text
        <tool_call>{"name":"b","arguments":{"x":1}}</tool_call>
        """
        let deltas = parser.process(stream) + parser.flush()
        var names: [String] = []
        for d in deltas {
            if case .toolCallStart(_, let name) = d { names.append(name) }
        }
        XCTAssertEqual(names, ["a", "b"])
    }

    func testMalformedJsonFallsBackToTextDelta() {
        let parser = ToolCallParser(syntax: .gemma)
        let stream = "<tool_call>not valid json</tool_call>"
        let deltas = parser.process(stream) + parser.flush()
        // With no extractable "name"/arguments, parser surfaces the
        // block as raw text so downstream logging can investigate.
        var joined = ""
        for d in deltas {
            if case .text(let t) = d { joined += t }
        }
        XCTAssertTrue(joined.contains("<tool_call>"))
        XCTAssertTrue(joined.contains("</tool_call>"))
    }

    // MARK: – Prompt rendering

    func testRenderToolsSectionIncludesToolNameForGemma() {
        let declaration = ToolDeclaration(
            name: "weather.get",
            description: "Return the current weather for a city",
            parameters: .object(.init(
                properties: [
                    "city": .primitive(.init(type: "string", description: "city name")),
                ],
                required: ["city"],
                description: nil
            ))
        )
        let section = ToolCallPrompts.renderToolsSection([declaration], syntax: .gemma)
        XCTAssertTrue(section.contains("<tools>"))
        XCTAssertTrue(section.contains("weather.get"))
        XCTAssertTrue(section.contains("<tool_call>"))
    }

    func testRenderToolsSectionSwitchesToLlamaFormat() {
        let declaration = ToolDeclaration(
            name: "search",
            description: "Search the web",
            parameters: .object(.init(
                properties: ["q": .primitive(.init(type: "string"))],
                required: ["q"],
                description: nil
            ))
        )
        let section = ToolCallPrompts.renderToolsSection([declaration], syntax: .llama32)
        XCTAssertTrue(section.contains("<|python_tag|>"))
        XCTAssertTrue(section.contains("<|eom_id|>"))
        XCTAssertFalse(section.contains("<tool_call>"))
    }

    func testRenderToolsSectionEmptyReturnsEmpty() {
        XCTAssertEqual(
            ToolCallPrompts.renderToolsSection([], syntax: .gemma),
            ""
        )
    }
}
