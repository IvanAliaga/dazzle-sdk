// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// AnthropicClient (RN shim) — talks to Anthropic's `/v1/messages`
// API via the native bridge. The actual HTTP + SSE parsing happens
// in Kotlin (`AnthropicClient.kt` from the Android SDK) on Android
// and Swift (`AnthropicClient.swift` from the iOS SDK) on iOS — this
// file is a thin wrapper over a NativeModule + DeviceEventEmitter.
//
// Wire-format conversion (Dazzle Message[] → Anthropic content
// blocks, tool_result wrapping, SSE event parsing) lives in those
// two files. If Anthropic changes the API we edit two files
// (Kotlin + Swift), not four.
//
// See `docs/plans/05-http-clients-to-jsi-cpp.md` for the planned
// migration to a single C/C++ HTTP core (libdazzle.so) so the next
// HTTP-based provider doesn't pay the four-language cost again.

import { NativeModules } from 'react-native';
import { LLMClient } from '../agent/llmClient';
import { Completion, Delta, Message } from '../agent/message';
import { ToolDeclaration, serializeSchema } from '../agent/tool';
import { runNativeStream } from './_nativeLLMStream';

const { DazzleReactNative } = NativeModules;

export interface AnthropicOptions {
  model: string;
  apiKey: string;
  baseURL?: string;            // default https://api.anthropic.com/v1
  anthropicVersion?: string;   // default 2023-06-01
  maxTokens?: number;          // default 1024
  temperature?: number;
  topP?: number;
  extraHeaders?: Record<string, string>;
}

export class AnthropicClient implements LLMClient {
  readonly modelId: string;
  private handle: number | null = null;

  private constructor(model: string) { this.modelId = model; }

  /** Spawn a fresh Anthropic-backed client. The native side keeps
   *  the handle alive until `close()` runs — until then `complete`
   *  and `stream` re-use the same configuration with no per-call
   *  setup. */
  static async create(opts: AnthropicOptions): Promise<AnthropicClient> {
    if (!opts.model)  throw new Error('AnthropicClient: model is required');
    if (!opts.apiKey) throw new Error('AnthropicClient: apiKey is required');
    const c = new AnthropicClient(opts.model);
    c.handle = await DazzleReactNative.anthropicCreate({
      model:            opts.model,
      apiKey:           opts.apiKey,
      baseURL:          opts.baseURL          ?? 'https://api.anthropic.com/v1',
      anthropicVersion: opts.anthropicVersion ?? '2023-06-01',
      maxTokens:        opts.maxTokens        ?? 1024,
      ...(opts.temperature  !== undefined ? { temperature: opts.temperature } : {}),
      ...(opts.topP         !== undefined ? { topP:        opts.topP }        : {}),
      ...(opts.extraHeaders ? { extraHeaders: opts.extraHeaders } : {}),
    });
    return c;
  }

  async complete(args: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): Promise<Completion> {
    if (this.handle == null) throw new Error('AnthropicClient.create() not awaited');
    const raw = await DazzleReactNative.anthropicComplete({
      handle:   this.handle,
      messages: args.messages.map(encodeMessage),
      tools:    (args.tools ?? []).map(encodeTool),
    });
    const content = (raw?.content as string) ?? '';
    if (raw?.type === 'toolCalls') {
      const toolCalls = ((raw.toolCalls as any[]) ?? []).map((c) => ({
        id:        String(c.id ?? ''),
        name:      String(c.name ?? ''),
        arguments: String(c.arguments ?? '{}'),
      }));
      return {
        type: 'toolCalls',
        message: { role: 'assistant', content, toolCalls },
      };
    }
    return {
      type: 'text',
      message: { role: 'assistant', content },
    };
  }

  stream(args: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): AsyncIterable<Delta> {
    if (this.handle == null) throw new Error('AnthropicClient.create() not awaited');
    return runNativeStream(
      {
        eventName: 'onAnthropicToken',
        start: (a) => DazzleReactNative.anthropicStream(a),
      },
      {
        handle:   this.handle,
        messages: args.messages.map(encodeMessage),
        tools:    (args.tools ?? []).map(encodeTool),
      },
    );
  }

  async close(): Promise<void> {
    if (this.handle != null) {
      await DazzleReactNative.anthropicClose(this.handle);
      this.handle = null;
    }
  }
}

// ── helpers ──────────────────────────────────────────────────────────

function encodeMessage(m: Message): any {
  const out: any = { role: m.role, content: m.content };
  if (m.toolCallId) out.toolCallId = m.toolCallId;
  if (m.toolCalls?.length) {
    out.toolCalls = m.toolCalls.map((c) => ({
      id: c.id, name: c.name, arguments: c.arguments,
    }));
  }
  return out;
}

function encodeTool(t: ToolDeclaration): any {
  return {
    name:        t.name,
    description: t.description,
    parameters:  serializeSchema(t.parameters),
  };
}
