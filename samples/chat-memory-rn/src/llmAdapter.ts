// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// THE ONE FILE YOU EDIT WHEN YOU WANT A DIFFERENT LLM RUNTIME.
// Mirror of samples/_shared/{android,ios,flutter}/*LLMAdapter*.
// See chat-iot-rn/src/llmAdapter.ts for the same 4-block layout.

import { NativeModules } from 'react-native';
import {
  Completion, FakeLLMClient, LLMClient,
  LlamaCppClient,
  LiteRtLmClient,
  FoundationModelsClient,
  OpenAICompatibleClient,
  AnthropicClient,
} from 'dazzle-react-native';

const { DazzleReactNative } = NativeModules;

function readEnv(name: string): string {
  try {
    const v = DazzleReactNative?.getEnv?.(name);
    if (typeof v === 'string' && v.length > 0) return v;
  } catch {}
  return process.env?.[name] ?? '';
}

export let isDemoFallback = false;

export async function makeLLMClient(): Promise<LLMClient> {

  // ─── A ─── llama.cpp — any GGUF model.
  // return await LlamaCppClient.create({
  //   modelPath: '/data/local/tmp/qwen2.5-0.5b-instruct-q4_k_m.gguf',
  //   systemPrompt: 'You are a helpful on-device AI assistant.',
  //   temperature: 0.3, maxTokens: 192, nThreads: 4,
  // });

  // ─── B ─── LiteRT-LM (.litertlm) — Android + iOS (our port).
  // return await LiteRtLmClient.create({
  //   modelPath: '/data/local/tmp/gemma4-e2b-it.litertlm',
  //   systemPrompt: 'You are a helpful on-device AI assistant.',
  //   temperature: 0.3, maxTokens: 512,
  // });

  // ─── C ─── Apple Foundation Models (iOS 26+).
  // if (await FoundationModelsClient.isAvailable()) {
  //   return new FoundationModelsClient({
  //     systemPrompt: 'You are a helpful on-device AI assistant.',
  //     temperature: 0.3, maxTokens: 512,
  //   });
  // }

  // ─── D ─── OpenAI-compatible HTTP. Reads OPENAI_API_KEY / HF_TOKEN
  //          from the env so `npm run` works without code edits.
  const openAiKey = readEnv('OPENAI_API_KEY');
  const hfToken   = readEnv('HF_TOKEN');
  if (openAiKey) {
    return new OpenAICompatibleClient({
      baseURL: 'https://api.openai.com/v1',
      model:   'gpt-4o-mini',
      apiKey:  openAiKey,
      temperature: 0.3, maxTokens: 512,
    });
  }
  if (hfToken) {
    return new OpenAICompatibleClient({
      baseURL: 'https://router.huggingface.co/v1',
      model:   'meta-llama/Llama-3.3-70B-Instruct',
      apiKey:  hfToken,
      temperature: 0.3, maxTokens: 512,
    });
  }

  // ─── E ─── Anthropic (Claude). Native bridge to the Kotlin/Swift
  //          `AnthropicClient` — JS doesn't re-implement HTTP/SSE.
  const anthropicKey = readEnv('ANTHROPIC_API_KEY');
  if (anthropicKey) {
    return await AnthropicClient.create({
      model:       'claude-3-5-sonnet-latest',
      apiKey:      anthropicKey,
      maxTokens:   1024,
      temperature: 0.3,
    });
  }

  // Fallback demo so the screen renders something.
  isDemoFallback = true;
  return makeDemoFake();
}

function makeDemoFake(): LLMClient {
  const canned: Completion[] = [
    { type: 'text', message: { role: 'assistant',
        content: "Hi! This is chat-memory-rn running in demo mode. " +
                 "Set OPENAI_API_KEY or HF_TOKEN, or uncomment a local " +
                 "adapter (LlamaCpp/LiteRtLm/Foundation) for a real LLM." } },
    { type: 'text', message: { role: 'assistant',
        content: "Every turn lands in a Dazzle hash under " +
                 "agent:chat-memory-default:memory:<id>. Restart the app — " +
                 "your conversation comes back." } },
  ];
  const base = new FakeLLMClient('demo:memory-fake', canned);
  return {
    modelId: 'demo:memory-fake',
    complete: async () => {
      if ((base as any).cursor >= canned.length) (base as any).cursor = 0;
      return base.complete();
    },
    stream: async function* () {
      if ((base as any).cursor >= canned.length) (base as any).cursor = 0;
      yield* base.stream();
    },
    close: () => base.close(),
  };
}
