// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

export type JsonSchema =
  | JsonSchemaObject
  | JsonSchemaPrimitive
  | JsonSchemaArray;

export interface JsonSchemaObject {
  readonly type: 'object';
  readonly description?: string;
  readonly properties: Array<[string, JsonSchema]>;
  readonly required: string[];
}

export interface JsonSchemaPrimitive {
  readonly type: 'string' | 'integer' | 'number' | 'boolean';
  readonly description?: string;
  readonly enumValues?: string[];
  readonly minimum?: number;
  readonly maximum?: number;
}

export interface JsonSchemaArray {
  readonly type: 'array';
  readonly items: JsonSchema;
  readonly description?: string;
}

export function serializeSchema(s: JsonSchema): string {
  return JSON.stringify(toJson(s));
}

function toJson(s: JsonSchema): any {
  switch (s.type) {
    case 'object': {
      const props: Record<string, any> = {};
      for (const [k, v] of s.properties) props[k] = toJson(v);
      const out: any = { type: 'object', properties: props };
      if (s.description) out.description = s.description;
      if (s.required.length) out.required = s.required;
      return out;
    }
    case 'array': {
      const out: any = { type: 'array', items: toJson(s.items) };
      if (s.description) out.description = s.description;
      return out;
    }
    default: {
      const out: any = { type: s.type };
      if (s.description) out.description = s.description;
      if (s.enumValues?.length) out.enum = s.enumValues;
      if (s.minimum !== undefined) out.minimum = s.minimum;
      if (s.maximum !== undefined) out.maximum = s.maximum;
      return out;
    }
  }
}

export interface SchemaBuilder {
  property(name: string, spec: Omit<JsonSchemaPrimitive, 'type'> & {
    type: JsonSchemaPrimitive['type'];
    required?: boolean;
  }): void;
  propertySchema(name: string, schema: JsonSchema, required?: boolean): void;
}

export function jsonSchemaObject(
    opts: { description?: string },
    build: (b: SchemaBuilder) => void): JsonSchemaObject {
  const properties: Array<[string, JsonSchema]> = [];
  const required: string[] = [];
  const b: SchemaBuilder = {
    property(name, spec) {
      const { type, required: req, ...rest } = spec;
      properties.push([name, { type, ...rest }]);
      if (req) required.push(name);
    },
    propertySchema(name, schema, req = false) {
      properties.push([name, schema]);
      if (req) required.push(name);
    },
  };
  build(b);
  return {
    type: 'object',
    description: opts.description,
    properties,
    required,
  };
}

export interface ToolDeclaration {
  readonly name: string;
  readonly description: string;
  readonly parameters: JsonSchema;
}

export interface ToolContext {
  readonly stores: Record<string, unknown>;
}

export interface Tool<Args = unknown, Ret = unknown> {
  readonly name: string;
  readonly description: string;
  readonly argsSchema: JsonSchema;
  argsFromJson(raw: string): Args;
  returnToJson(value: Ret): string;
  invoke(args: Args, ctx: ToolContext): Promise<Ret>;
}

export async function invokeToolRaw(
    tool: Tool, raw: string, ctx: ToolContext): Promise<string> {
  const args = tool.argsFromJson(raw);
  const result = await tool.invoke(args, ctx);
  return tool.returnToJson(result);
}

export function toolToDeclaration(t: Tool): ToolDeclaration {
  return { name: t.name, description: t.description, parameters: t.argsSchema };
}
