// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// FoundationModelsClient — Apple Intelligence 3B on iOS 26+ / macOS
// 26+. Platform-gated; Android callers get a clear error so they can
// fall back to LlamaCppClient.

import { NativeModules, Platform } from 'react-native';
import { LLMClient } from '../agent/llmClient';
import { Completion, Delta, Message } from '../agent/message';
import { ToolDeclaration } from '../agent/tool';
import { runNativeStream } from './_nativeLLMStream';

const { DazzleReactNative } = NativeModules;

export interface FoundationModelsOptions {
  systemPrompt?: string;
  temperature?: number;
  maxTokens?: number;
}

export class FoundationModelsClient implements LLMClient {
  readonly modelId = 'apple:foundation-models';
  private readonly opts: Required<FoundationModelsOptions>;

  constructor(opts: FoundationModelsOptions = {}) {
    this.opts = {
      systemPrompt: opts.systemPrompt ?? 'You are a helpful on-device AI assistant.',
      temperature:  opts.temperature  ?? 0.3,
      maxTokens:    opts.maxTokens    ?? 512,
    };
  }

  static async isAvailable(): Promise<boolean> {
    if (Platform.OS !== 'ios' && Platform.OS !== 'macos') return false;
    try {
      return !!(await DazzleReactNative.fmIsAvailable());
    } catch {
      return false;
    }
  }

  async complete(args: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): Promise<Completion> {
    let text = '';
    for await (const d of this.stream(args)) {
      if (d.type === 'text') text += d.chunk;
    }
    return { type: 'text', message: { role: 'assistant', content: text } };
  }

  stream(args: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): AsyncIterable<Delta> {
    if (Platform.OS !== 'ios' && Platform.OS !== 'macos') {
      throw new Error(
          'FoundationModelsClient is iOS/macOS 26+ only; use ' +
          'LlamaCppClient or OpenAICompatibleClient on other platforms.');
    }
    return runNativeStream(
      {
        eventName: 'onFoundationToken',
        start: (a) => DazzleReactNative.fmGenerate(a),
      },
      {
        systemPrompt: this.opts.systemPrompt,
        temperature:  this.opts.temperature,
        maxTokens:    this.opts.maxTokens,
        messages:     args.messages,
      },
    );
  }

  async close(): Promise<void> {}
}
