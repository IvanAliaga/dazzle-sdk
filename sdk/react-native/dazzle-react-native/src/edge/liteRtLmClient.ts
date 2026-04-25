// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// LiteRtLmClient — Android-only today (Google .litertlm files run on
// their JVM-side runtime). Drives the native LiteRtLmClient through a
// NativeModule.

import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import { LLMClient } from '../agent/llmClient';
import { Completion, Delta, Message } from '../agent/message';
import { ToolDeclaration } from '../agent/tool';

const { DazzleReactNative } = NativeModules;

export interface LiteRtLmOptions {
  modelPath: string;
  modelId?: string;
  systemPrompt?: string;
  temperature?: number;
  maxTokens?: number;
}

export class LiteRtLmClient implements LLMClient {
  readonly modelId: string;
  private readonly modelPath: string;
  private readonly opts: Required<Omit<LiteRtLmOptions, 'modelId' | 'modelPath'>>;
  private handle: number | null = null;

  private constructor(opts: LiteRtLmOptions) {
    this.modelPath = opts.modelPath;
    this.modelId   = opts.modelId ?? opts.modelPath.split('/').pop() ?? 'litertlm';
    this.opts = {
      systemPrompt: opts.systemPrompt ?? 'You are a helpful on-device AI assistant.',
      temperature:  opts.temperature  ?? 0.3,
      maxTokens:    opts.maxTokens    ?? 512,
    };
  }

  static async create(opts: LiteRtLmOptions): Promise<LiteRtLmClient> {
    if (Platform.OS !== 'android') {
      throw new Error(
          'LiteRtLmClient is Android-only today. Use LlamaCppClient or ' +
          'FoundationModelsClient on iOS.');
    }
    const c = new LiteRtLmClient(opts);
    c.handle = await DazzleReactNative.liteRtCreate({
      modelPath:    c.modelPath,
      systemPrompt: c.opts.systemPrompt,
      temperature:  c.opts.temperature,
      maxTokens:    c.opts.maxTokens,
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

  async *stream(args: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): AsyncIterable<Delta> {
    if (this.handle == null) {
      throw new Error('LiteRtLmClient.create() was not awaited');
    }
    const reqId = ++_reqCounter;
    const emitter = new NativeEventEmitter(DazzleReactNative);
    const queue: Delta[] = [];
    let finished = false;
    let waiter: (() => void) | null = null;

    const sub = emitter.addListener('onLiteRtToken', (evt: any) => {
      if (evt?.reqId !== reqId) return;
      if (evt?.type === 'text') queue.push({ type: 'text', chunk: evt.chunk ?? '' });
      else if (evt?.type === 'end' || evt?.type === 'error') {
        queue.push({ type: 'end' });
        finished = true;
      }
      if (waiter) { waiter(); waiter = null; }
    });

    try {
      void DazzleReactNative.liteRtGenerate({
        handle: this.handle,
        reqId,
        messages: args.messages,
      });
      while (true) {
        while (queue.length) {
          const d = queue.shift()!;
          yield d;
          if (d.type === 'end') return;
        }
        if (finished) return;
        await new Promise<void>((res) => { waiter = res; });
      }
    } finally {
      sub.remove();
    }
  }

  async close(): Promise<void> {
    if (this.handle != null) {
      await DazzleReactNative.liteRtClose(this.handle);
      this.handle = null;
    }
  }
}

let _reqCounter = 0;
