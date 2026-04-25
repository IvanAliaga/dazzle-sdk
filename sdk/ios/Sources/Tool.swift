// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Type-erased Tool facade — the view the `Agent` sees.
///
/// `Tool` refines this with typed `Args` / `Ret`. Type erasure lets
/// heterogeneous tools live in the same `[any ErasedTool]` collection
/// without forcing the caller to match associated types.
public protocol ErasedTool: Sendable {
    var name: String { get }
    var description: String { get }
    var argsSchema: JsonSchema { get }
    func toDeclaration() -> ToolDeclaration

    /// Invoke via raw JSON arguments. Default implementation on `Tool`
    /// decodes → invokes → encodes; custom conformers can override.
    func invokeRaw(arguments raw: String, ctx: ToolContext) async throws -> String
}

public extension ErasedTool {
    func toDeclaration() -> ToolDeclaration {
        ToolDeclaration(name: name, description: description, parameters: argsSchema)
    }
}

/// A typed function that an LLM / `Agent` can invoke during a conversation.
///
/// Serializes to the **OpenAI / Anthropic / Gemini function-calling format**
/// via `toDeclaration()`, so a `Tool` written in Swift is consumed as-is
/// by every modern LLM runtime.
public protocol Tool<Args, Ret>: ErasedTool {
    associatedtype Args
    associatedtype Ret

    /// Execute the tool. Called after `argsFromJson(_:)` decodes the
    /// LLM's tool_call arguments into typed `Args`.
    func invoke(args: Args, ctx: ToolContext) async throws -> Ret

    /// Decode the LLM's tool_call `arguments` JSON into typed `Args`.
    func argsFromJson(_ raw: String) throws -> Args

    /// Encode the return value back to a JSON string that the SDK
    /// appends as the content of a `role == .tool` response message.
    func returnToJson(_ value: Ret) -> String
}

public extension Tool {
    /// Default erased invocation: decode → invoke → encode.
    func invokeRaw(arguments raw: String, ctx: ToolContext) async throws -> String {
        let args = try argsFromJson(raw)
        let result = try await invoke(args: args, ctx: ctx)
        return returnToJson(result)
    }
}

/// Wire-format tool declaration. Serialize to JSON and paste directly
/// into an OpenAI `tools: [...]` array — no adapter needed.
public struct ToolDeclaration: Sendable {
    public let name: String
    public let description: String
    public let parameters: JsonSchema

    public init(name: String, description: String, parameters: JsonSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Execution context available inside `Tool.invoke`.
public struct ToolContext: @unchecked Sendable {
    /// Threading / concurrency settings inherited from the agent.
    public let execution: ExecutionPolicy
    /// Named context stores the tool can read from or write to.
    public let stores: [String: any ContextStoreBox]
    /// Reserved for multi-agent pub/sub (Layer 3+).
    public let publish: (@Sendable (String, String) async -> Void)?

    public init(
        execution: ExecutionPolicy,
        stores: [String: any ContextStoreBox] = [:],
        publish: (@Sendable (String, String) async -> Void)? = nil
    ) {
        self.execution = execution
        self.stores = stores
        self.publish = publish
    }
}

/// Type-erasing wrapper so `ToolContext` can carry heterogeneous
/// `ContextStore<T>` values. Concrete stores conform automatically.
public protocol ContextStoreBox: AnyObject, Sendable {
    var name: String { get }
}

// ── JsonSchema ───────────────────────────────────────────────────────────

/// Minimal JSON Schema representation — enough to describe tool
/// parameter shapes without pulling a full JSON Schema implementation.
public indirect enum JsonSchema: Sendable {
    /// A parameters object with named fields.
    case object(properties: [(String, JsonSchema)], required: [String], description: String?)
    /// A scalar: "string" / "integer" / "number" / "boolean".
    case primitive(type: String, description: String?, enumValues: [String]?, minimum: Double?, maximum: Double?)
    /// An array of a single item shape.
    case array(items: JsonSchema, description: String?)
    /// Pass-through — the JSON string was already built in Dart / TS
    /// and the native layer only needs to forward it verbatim into
    /// the LLM prompt. Used by the Flutter + React Native bridges.
    case raw(json: String)

    /// Emit this schema as a JSON string (OpenAI-compatible).
    public func serialize() -> String {
        switch self {
        case .object(let props, let required, let desc):
            var s = "{\"type\":\"object\""
            if let desc = desc { s += ",\"description\":\"\(JsonSchema.escape(desc))\"" }
            s += ",\"properties\":{"
            for (i, (k, v)) in props.enumerated() {
                if i > 0 { s += "," }
                s += "\"\(JsonSchema.escape(k))\":\(v.serialize())"
            }
            s += "}"
            if !required.isEmpty {
                s += ",\"required\":["
                for (i, r) in required.enumerated() {
                    if i > 0 { s += "," }
                    s += "\"\(JsonSchema.escape(r))\""
                }
                s += "]"
            }
            return s + "}"
        case .primitive(let type, let desc, let enumVals, let minV, let maxV):
            precondition(["string", "integer", "number", "boolean"].contains(type),
                "unsupported primitive type: \(type)")
            var s = "{\"type\":\"\(type)\""
            if let desc = desc { s += ",\"description\":\"\(JsonSchema.escape(desc))\"" }
            if let e = enumVals, !e.isEmpty {
                s += ",\"enum\":["
                for (i, v) in e.enumerated() {
                    if i > 0 { s += "," }
                    s += "\"\(JsonSchema.escape(v))\""
                }
                s += "]"
            }
            if let m = minV { s += ",\"minimum\":\(m)" }
            if let m = maxV { s += ",\"maximum\":\(m)" }
            return s + "}"
        case .array(let items, let desc):
            var s = "{\"type\":\"array\",\"items\":\(items.serialize())"
            if let desc = desc { s += ",\"description\":\"\(JsonSchema.escape(desc))\"" }
            return s + "}"
        case .raw(let json):
            return json
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:    out.append(c)
            }
        }
        return out
    }
}

// ── Builder DSL for JsonSchema.object ───────────────────────────────────

/// Build a JsonSchema object with a fluent API.
///
/// ```swift
/// let schema = jsonSchemaObject(description: "Weather query") {
///     $0.property("city", type: "string", required: true,
///                 description: "City name, e.g. 'Lima'")
///     $0.property("unit", type: "string",
///                 description: "C or F", enum: ["C", "F"])
/// }
/// ```
public func jsonSchemaObject(
    description: String? = nil,
    _ build: (inout JsonSchemaObjectBuilder) -> Void
) -> JsonSchema {
    var b = JsonSchemaObjectBuilder(description: description)
    build(&b)
    return b.build()
}

public struct JsonSchemaObjectBuilder {
    private let description: String?
    private var properties: [(String, JsonSchema)] = []
    private var required: [String] = []

    fileprivate init(description: String?) { self.description = description }

    public mutating func property(
        _ name: String,
        type: String,
        description: String? = nil,
        required: Bool = false,
        `enum` enumValues: [String]? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        let s = JsonSchema.primitive(
            type: type,
            description: description,
            enumValues: enumValues,
            minimum: minimum,
            maximum: maximum
        )
        properties.append((name, s))
        if required { self.required.append(name) }
    }

    public mutating func property(_ name: String, schema: JsonSchema, required: Bool = false) {
        properties.append((name, schema))
        if required { self.required.append(name) }
    }

    fileprivate func build() -> JsonSchema {
        .object(properties: properties, required: required, description: description)
    }
}
