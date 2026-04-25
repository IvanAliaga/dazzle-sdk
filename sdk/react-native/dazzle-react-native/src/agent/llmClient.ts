// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { NativeModules } from 'react-native';

import { Completion, Delta, Message } from './message';
import { ToolDeclaration } from './tool';

const { DazzleReactNative } = NativeModules;

/** Shut the process down — used by the sample-test harness so the
 *  next launch comes up fresh on the normal UI. No-op if the native
 *  module is not linked. */
export function exitProcess(): Promise<void> {
  return DazzleReactNative?.exitProcess
    ? DazzleReactNative.exitProcess()
    : Promise.resolve();
}

export interface LLMClient {
  readonly modelId: string;
  complete(opts: {
    messages: Message[];
    tools?: ToolDeclaration[];
  }): Promise<Completion>;
  stream(opts: {
    messages: Message[];
    tools?: ToolDeclaration[];
  }): AsyncIterable<Delta>;
  close(): Promise<void>;
}

/** Scripted fake — mirrors native FakeLLMClient. */
export class FakeLLMClient implements LLMClient {
  constructor(
      readonly modelId: string = 'fake:test',
      private readonly script: Completion[] = []) {}

  private cursor = 0;
  get callCount(): number { return this.cursor; }

  async complete(): Promise<Completion> {
    if (this.cursor >= this.script.length) {
      throw new Error('FakeLLMClient script exhausted');
    }
    return this.script[this.cursor++];
  }

  async *stream(): AsyncIterable<Delta> {
    if (this.cursor >= this.script.length) {
      throw new Error('FakeLLMClient script exhausted');
    }
    const next = this.script[this.cursor++];
    if (next.type === 'text') {
      const text = next.message.content;
      for (let i = 0; i < text.length; i += 8) {
        yield { type: 'text', chunk: text.substring(i, Math.min(i + 8, text.length)) };
      }
    } else {
      for (const call of next.message.toolCalls ?? []) {
        yield { type: 'toolCallStart', id: call.id, name: call.name };
        const args = call.arguments;
        for (let i = 0; i < args.length; i += 8) {
          yield { type: 'toolCallArgs', id: call.id,
                  chunk: args.substring(i, Math.min(i + 8, args.length)) };
        }
      }
    }
    yield { type: 'end' };
  }

  async close(): Promise<void> {}
}
