// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

/// Tool declarations + schema, matching `Tool.kt` / `Tool.swift`. The
/// ChatAgent serialises a list of [ToolDeclaration] into the shape
/// OpenAI / Anthropic / Gemini function-calling wire formats expect —
/// the SAME schema JSON the native SDKs emit.

import 'dart:convert';

/// JSON Schema subset — object / primitive / array. Enough to describe
/// every tool we've shipped across samples + third-party consumers.
sealed class JsonSchema {
  const JsonSchema();
  String serialize();
}

class JsonSchemaObject extends JsonSchema {
  final String? description;
  final List<(String, JsonSchema)> properties;
  final List<String> required;
  const JsonSchemaObject({
    this.description,
    this.properties = const [],
    this.required = const [],
  });

  @override
  String serialize() {
    final sb = StringBuffer('{"type":"object"');
    if (description != null) sb.write(',"description":${jsonEncode(description)}');
    sb.write(',"properties":{');
    for (var i = 0; i < properties.length; i++) {
      if (i > 0) sb.write(',');
      final (k, v) = properties[i];
      sb..write(jsonEncode(k))..write(':')..write(v.serialize());
    }
    sb.write('}');
    if (required.isNotEmpty) {
      sb..write(',"required":[')
        ..write(required.map(jsonEncode).join(','))
        ..write(']');
    }
    sb.write('}');
    return sb.toString();
  }
}

class JsonSchemaPrimitive extends JsonSchema {
  final String type; // "string" | "integer" | "number" | "boolean"
  final String? description;
  final List<String>? enumValues;
  final double? minimum;
  final double? maximum;
  const JsonSchemaPrimitive({
    required this.type,
    this.description,
    this.enumValues,
    this.minimum,
    this.maximum,
  });

  @override
  String serialize() {
    assert(['string', 'integer', 'number', 'boolean'].contains(type),
        'unsupported primitive $type');
    final sb = StringBuffer('{"type":${jsonEncode(type)}');
    if (description != null) sb.write(',"description":${jsonEncode(description)}');
    if (enumValues != null && enumValues!.isNotEmpty) {
      sb..write(',"enum":[')
        ..write(enumValues!.map(jsonEncode).join(','))
        ..write(']');
    }
    if (minimum != null) sb.write(',"minimum":$minimum');
    if (maximum != null) sb.write(',"maximum":$maximum');
    sb.write('}');
    return sb.toString();
  }
}

class JsonSchemaArray extends JsonSchema {
  final JsonSchema items;
  final String? description;
  const JsonSchemaArray({required this.items, this.description});

  @override
  String serialize() {
    final sb = StringBuffer('{"type":"array","items":')
      ..write(items.serialize());
    if (description != null) sb.write(',"description":${jsonEncode(description)}');
    sb.write('}');
    return sb.toString();
  }
}

/// Builder DSL — same pattern Kotlin / Swift expose.
JsonSchemaObject jsonSchemaObject(
    {String? description, required void Function(_SchemaBuilder) build}) {
  final b = _SchemaBuilder(description);
  build(b);
  return b._toSchema();
}

class _SchemaBuilder {
  _SchemaBuilder(this._description);
  final String? _description;
  final List<(String, JsonSchema)> _properties = [];
  final List<String> _required = [];

  void property(
    String name, {
    required String type,
    String? description,
    bool required = false,
    List<String>? enumValues,
    double? minimum,
    double? maximum,
  }) {
    _properties.add((
      name,
      JsonSchemaPrimitive(
        type: type,
        description: description,
        enumValues: enumValues,
        minimum: minimum,
        maximum: maximum,
      ),
    ));
    if (required) _required.add(name);
  }

  void propertySchema(String name, JsonSchema schema, {bool required = false}) {
    _properties.add((name, schema));
    if (required) _required.add(name);
  }

  JsonSchemaObject _toSchema() => JsonSchemaObject(
        description: _description,
        properties: _properties,
        required: _required,
      );
}

class ToolDeclaration {
  final String name;
  final String description;
  final JsonSchema parameters;
  const ToolDeclaration({
    required this.name,
    required this.description,
    required this.parameters,
  });
}

class ToolContext {
  final Map<String, Object> stores;
  const ToolContext({this.stores = const {}});
}

/// A typed tool that the agent can invoke.
///
/// `Args` should be a plain Dart class (or Map<String,dynamic>) that
/// round-trips through JSON; the ChatAgent decodes `arguments` JSON
/// into an `Args`, calls [invoke], then re-encodes the `Ret` into JSON
/// that the LLM sees as the tool response.
abstract class Tool<Args, Ret> {
  String get name;
  String get description;
  JsonSchema get argsSchema;

  Future<Ret> invoke(Args args, ToolContext ctx);
  Args argsFromJson(String raw);
  String returnToJson(Ret value);

  ToolDeclaration toDeclaration() => ToolDeclaration(
        name: name, description: description, parameters: argsSchema,
      );

  /// Default erased invocation — the ChatAgent calls this.
  Future<String> invokeRaw(String raw, ToolContext ctx) async {
    final args = argsFromJson(raw);
    final result = await invoke(args, ctx);
    return returnToJson(result);
  }
}
