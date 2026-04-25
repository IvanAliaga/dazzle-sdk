// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// LlamaCppClient — same llama.cpp statically linked into libdazzle
// that the native Android/iOS SDKs use. The bridge to JS is via the
// DazzleReactNative NativeModule: `create` sets up the model + ctx on
// the native side, `complete`/`stream` forward through the module
// where the native code runs the decode loop and emits `onToken`
// events back through DeviceEventEmitter.

import { NativeModules } from 'react-native';
import { LLMClient } from '../agent/llmClient';
import { Completion, Delta, Message } from '../agent/message';
import { ToolDeclaration } from '../agent/tool';
import { runNativeStream } from './_nativeLLMStream';

const { DazzleReactNative } = NativeModules;

export interface LlamaCppOptions {
  modelPath: string;
  modelId?: string;
  systemPrompt?: string;
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  nCtx?: number;
  nThreads?: number;
  seed?: number;
}

export class LlamaCppClient implements LLMClient {
  readonly modelId: string;
  private readonly modelPath: string;
  private readonly opts: Required<Omit<LlamaCppOptions, 'modelId' | 'modelPath'>>;
  private handle: number | null = null;

  private constructor(opts: LlamaCppOptions) {
    this.modelPath = opts.modelPath;
    this.modelId = opts.modelId ??
        opts.modelPath.split('/').pop()?.replace(/\.gguf$/, '') ??
        'llamacpp';
    this.opts = {
      systemPrompt: opts.systemPrompt ?? 'You are a helpful on-device AI assistant.',
      temperature: opts.temperature ?? 0.3,
      topP:        opts.topP        ?? 0.95,
      maxTokens:   opts.maxTokens   ?? 512,
      nCtx:        opts.nCtx        ?? 2048,
      nThreads:    opts.nThreads    ?? 4,
      seed:        opts.seed        ?? 0xD4771E,
    };
  }

  static async create(opts: LlamaCppOptions): Promise<LlamaCppClient> {
    const c = new LlamaCppClient(opts);
    c.handle = await DazzleReactNative.llamaCreate({
      modelPath: c.modelPath,
      nCtx:      c.opts.nCtx,
      nThreads:  c.opts.nThreads,
      seed:      c.opts.seed,
    });
    return c;
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
    if (this.handle == null) {
      throw new Error('LlamaCppClient.create() was not awaited');
    }
    return runNativeStream(
      {
        eventName: 'onLlamaToken',
        start: (a) => DazzleReactNative.llamaGenerate(a),
      },
      {
        handle:      this.handle,
        prompt:      this.renderPrompt(args.messages),
        maxTokens:   this.opts.maxTokens,
        temperature: this.opts.temperature,
        topP:        this.opts.topP,
      },
    );
  }

  async close(): Promise<void> {
    if (this.handle != null) {
      await DazzleReactNative.llamaClose(this.handle);
      this.handle = null;
    }
  }

  private renderPrompt(messages: Message[]): string {
    const parts = [this.opts.systemPrompt
      ? `<|im_start|>system\n${this.opts.systemPrompt}<|im_end|>\n`
      : ''];
    for (const m of messages) {
      parts.push(`<|im_start|>${m.role}\n${m.content}<|im_end|>\n`);
    }
    parts.push('<|im_start|>assistant\n');
    return parts.join('');
  }
}
