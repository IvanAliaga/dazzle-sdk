// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

/// Unit tests for `OpenAICompatibleClient`. Intercept outbound
/// `URLSession` traffic with a custom `URLProtocol` so the suite
/// never touches the network — canned HTTP bodies cover JSON and SSE
/// paths without requiring `XCTestServer`.
final class OpenAICompatibleClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: cfg)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: – Non-streaming

    func testCompleteReturnsTextMessage() async throws {
        MockURLProtocol.respondJson("""
        {"choices":[{"message":{"role":"assistant","content":"hola, mundo"}}]}
        """)
        let client = makeClient()
        let reply = try await client.complete(
            messages: [Message(role: .user, content: "hi")],
            tools: []
        )
        guard case .text(let msg) = reply else {
            return XCTFail("expected .text, got \(reply)")
        }
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "hola, mundo")
    }

    func testCompleteReturnsToolCalls() async throws {
        let body = """
        {"choices":[{"message":{"role":"assistant","content":null,
        "tool_calls":[{"id":"call_1","type":"function",
        "function":{"name":"weather_get","arguments":"{\\"city\\":\\"Lima\\"}"}}]}}]}
        """.replacingOccurrences(of: "\n", with: "")
        MockURLProtocol.respondJson(body)
        let reply = try await makeClient().complete(
            messages: [Message(role: .user, content: "weather?")],
            tools: []
        )
        guard case .toolCalls(let msg) = reply else {
            return XCTFail("expected .toolCalls, got \(reply)")
        }
        XCTAssertEqual(msg.toolCalls.count, 1)
        XCTAssertEqual(msg.toolCalls[0].id, "call_1")
        XCTAssertEqual(msg.toolCalls[0].name, "weather_get")
        XCTAssertEqual(msg.toolCalls[0].arguments, "{\"city\":\"Lima\"}")
    }

    func testCompleteSendsApiKeyAsBearer() async throws {
        MockURLProtocol.respondJson("""
        {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
        """)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "https://api.example.test/v1")!,
            model: "gpt-4o-mini",
            apiKey: "sk-TEST-123",
            session: session
        )
        _ = try await client.complete(
            messages: [Message(role: .user, content: "ping")],
            tools: []
        )
        XCTAssertEqual(MockURLProtocol.lastAuthorization, "Bearer sk-TEST-123")
    }

    func testCompleteSendsModelAndMessagesInBody() async throws {
        MockURLProtocol.respondJson("""
        {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
        """)
        _ = try await makeClient(model: "llama-3.3-70b").complete(
            messages: [
                Message(role: .system, content: "be brief"),
                Message(role: .user,   content: "hi"),
            ],
            tools: []
        )
        let body = try XCTUnwrap(MockURLProtocol.lastBodyJson())
        XCTAssertEqual(body["model"] as? String, "llama-3.3-70b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let msgs = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        XCTAssertEqual(msgs[1]["role"] as? String, "user")
    }

    // MARK: – Streaming

    func testStreamYieldsTextDeltasAndEnd() async throws {
        MockURLProtocol.respondSSE([
            "{\"choices\":[{\"delta\":{\"content\":\"Hola\"}}]}",
            "{\"choices\":[{\"delta\":{\"content\":\", mundo\"}}]}",
            "[DONE]",
        ])
        var deltas: [Delta] = []
        for try await d in makeClient().stream(
            messages: [Message(role: .user, content: "hi")],
            tools: []
        ) {
            deltas.append(d)
        }
        let joined = deltas.reduce("") { acc, d in
            if case .text(let t) = d { return acc + t }
            return acc
        }
        XCTAssertEqual(joined, "Hola, mundo")
        XCTAssertEqual(deltas.last, .end)
    }

    func testStreamYieldsToolCallDeltas() async throws {
        MockURLProtocol.respondSSE([
            "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"weather_get\"}}]}}]}",
            "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\"\"}}]}}]}",
            "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"Lima\\\"}\"}}]}}]}",
            "[DONE]",
        ])
        var starts: [String] = []
        var argsChunks: [String] = []
        for try await d in makeClient().stream(
            messages: [Message(role: .user, content: "w?")],
            tools: []
        ) {
            switch d {
            case .toolCallStart(_, let name): starts.append(name)
            case .toolCallArgs(_, let c):     argsChunks.append(c)
            default: break
            }
        }
        XCTAssertEqual(starts, ["weather_get"])
        XCTAssertEqual(argsChunks.joined(), "{\"city\":\"Lima\"}")
    }

    // MARK: – HTTP errors

    func testCompleteThrowsHttpErrorOn401() async {
        MockURLProtocol.respondStatus(401, body: #"{"error":{"message":"invalid api key"}}"#)
        do {
            _ = try await makeClient().complete(
                messages: [Message(role: .user, content: "hi")],
                tools: []
            )
            XCTFail("expected httpError")
        } catch OpenAICompatibleError.httpError(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid api key"))
        } catch {
            XCTFail("expected httpError, got \(error)")
        }
    }

    // MARK: – Helpers

    private func makeClient(model: String = "gpt-4o-mini") -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            baseURL: URL(string: "https://api.example.test/v1")!,
            model: model,
            session: session
        )
    }
}

// MARK: – MockURLProtocol

/// Intercepts every `URLRequest` routed through a
/// `URLSessionConfiguration` with this class in `protocolClasses`.
/// One canned response per test, plus capture of the most recent
/// `Authorization` header + request body.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    private enum Script {
        case json(status: Int, body: String)
        case sse(frames: [String])
    }

    nonisolated(unsafe) private static var script: Script = .json(status: 200, body: "{}")
    nonisolated(unsafe) static var lastAuthorization: String?
    nonisolated(unsafe) static var lastBody: Data = Data()

    static func reset() {
        script = .json(status: 200, body: "{}")
        lastAuthorization = nil
        lastBody = Data()
    }

    static func respondJson(_ body: String) {
        script = .json(status: 200, body: body)
    }
    static func respondStatus(_ code: Int, body: String) {
        script = .json(status: code, body: body)
    }
    static func respondSSE(_ frames: [String]) {
        script = .sse(frames: frames)
    }

    static func lastBodyJson() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: lastBody)) as? [String: Any]
    }

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture the inbound request for assertions.
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            Self.lastBody = body
        } else if let body = request.httpBody {
            Self.lastBody = body
        }

        switch Self.script {
        case .json(let status, let body):
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)

        case .sse(let frames):
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            for frame in frames {
                let line = "data: \(frame)\n\n"
                client?.urlProtocol(self, didLoad: Data(line.utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { /* no-op */ }
}
