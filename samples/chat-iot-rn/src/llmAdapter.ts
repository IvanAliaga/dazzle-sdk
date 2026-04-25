// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// THE ONE FILE YOU EDIT WHEN YOU WANT A DIFFERENT LLM RUNTIME.
// Mirror of samples/_shared/{android,ios,flutter}/*LLMAdapter* — uncomment
// the adapter you want; comment the rest. Falls back to a looped
// FakeLLMClient so `npm run android|ios` renders a working UI out of the
// box (with a banner nudging you to wire a real LLM).
//
// Five adapters ship in the SDK:
//
//   A. LlamaCppClient         — any GGUF model (Llama / Gemma / Qwen / …)
//   B. LiteRtLmClient         — Google's .litertlm format. Android +
//                               iOS (we ship the iOS port; nobody else
//                               has LiteRT-LM running on iPhone).
//   C. FoundationModelsClient — iOS / macOS 26+ Apple Intelligence.
//   D. OpenAICompatibleClient — OpenAI / HF Router / Ollama / vLLM /
//                               Groq / Together / llama-server.
//   E. AnthropicClient        — Anthropic Claude `/v1/messages` API.

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

export let isDemoFallback = false;

/** Read a name from the native process env. RN's `process.env` is
 *  empty by default — Metro doesn't ship the host env into the
 *  bundle. The native `getEnv` bridge reads from
 *  `ProcessInfo.processInfo.environment` on iOS and the Activity's
 *  intent extras on Android. */
function readEnv(name: string): string {
  try {
    const v = DazzleReactNative?.getEnv?.(name);
    if (typeof v === 'string' && v.length > 0) return v;
  } catch { /* ignore */ }
  return process.env?.[name] ?? '';
}

export async function makeLLMClient(): Promise<LLMClient> {

  // ─── A ─── llama.cpp — any GGUF model.
  // return await LlamaCppClient.create({
  //   modelPath: '/data/local/tmp/qwen2.5-0.5b-instruct-q4_k_m.gguf', // Android
  //   // iOS: ship inside the app bundle or drop into Documents/.
  //   systemPrompt: 'You are a helpful on-device AI assistant.',
  //   temperature: 0.3,
  //   maxTokens:   192,
  //   nThreads:    4,
  // });

  // ─── B ─── LiteRT-LM (.litertlm) — Android + iOS (our port).
  // return await LiteRtLmClient.create({
  //   modelPath: '/data/local/tmp/gemma4-e2b-it.litertlm',
  //   systemPrompt: 'You are a helpful on-device AI assistant.',
  //   temperature: 0.3,
  //   maxTokens:   512,
  // });

  // ─── C ─── Apple Foundation Models (iOS 26+).
  // if (await FoundationModelsClient.isAvailable()) {
  //   return new FoundationModelsClient({
  //     systemPrompt: 'You are a helpful on-device AI assistant.',
  //     temperature: 0.3,
  //     maxTokens:   512,
  //   });
  // }

  // ─── D ─── OpenAI-compatible HTTP. Picks OPENAI_API_KEY / HF_TOKEN
  //          from the env so `npm run` works without code changes.
  const openAiKey = readEnv('OPENAI_API_KEY');
  const hfToken   = readEnv('HF_TOKEN');
  if (openAiKey) {
    return new OpenAICompatibleClient({
      baseURL: 'https://api.openai.com/v1',
      model:   'gpt-4o-mini',
      apiKey:  openAiKey,
      temperature: 0.3,
      maxTokens:   512,
    });
  }
  if (hfToken) {
    return new OpenAICompatibleClient({
      baseURL: 'https://router.huggingface.co/v1',
      model:   'meta-llama/Llama-3.3-70B-Instruct',
      apiKey:  hfToken,
      temperature: 0.3,
      maxTokens:   512,
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

  // ─── Fallback ─── No real adapter wired → demo fake so the UI loop
  //                 works for the screenshot. Banner nudges the user.
  isDemoFallback = true;
  return makeDemoFake();
}

function makeDemoFake(): LLMClient {
  const canned: Completion[] = [
    { type: 'toolCalls', message: { role: 'assistant', content: '',
        toolCalls: [{ id: 'c1', name: 'retrieve_anomalies',
                      arguments: '{"min_from":0,"min_to":800}' }] } },
    { type: 'text', message: { role: 'assistant',
        content: 'Demo mode — retrieved sensor windows for minute 0..800. ' +
                 'Set OPENAI_API_KEY or HF_TOKEN (or uncomment a local adapter) ' +
                 'to plug in a real LLM.' } },
  ];
  const base = new FakeLLMClient('demo:iot-fake', canned);
  return {
    modelId: 'demo:iot-fake',
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
