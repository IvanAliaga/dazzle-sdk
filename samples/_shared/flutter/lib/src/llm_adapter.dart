// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// ─────────────────────────────────────────────────────────────────────────
// THE ONE FILE YOU EDIT WHEN YOU WANT A DIFFERENT LLM RUNTIME.
//
// Every Dazzle Flutter sample — chat-memory-flutter, chat-iot-flutter,
// chat-kb-flutter — imports this file. The ChatScreen, the
// DazzleServer.shared.chatAgent wiring, and every Dazzle storage call
// are identical no matter which adapter you pick. That's the whole
// point of the LLMClient interface.
//
// Five adapters ship in the SDK:
//
//     A. LlamaCppClient         — any GGUF model, on-device
//                                 (Android .so + iOS xcframework).
//     B. LiteRtLmClient         — Google's .litertlm format, on-device
//                                 (Android native only today).
//     C. FoundationModelsClient — iOS 26+ / macOS 26+ only.
//     D. OpenAICompatibleClient — anything that speaks the OpenAI
//                                 REST shape (OpenAI, HF Router,
//                                 Ollama, vLLM, Groq, Together…).
//     E. AnthropicClient        — Anthropic Claude API directly
//                                 (`/v1/messages`, distinct shape
//                                 from OpenAI — `system` field, tool
//                                 use as content blocks, etc.)
//
// Default: LlamaCppClient with Qwen 2.5 1.5B Instruct (Q4_K_M), ~1 GB.
// Run `samples/_scripts/download_models.sh` once to fetch the weights
// and push them with `samples/_scripts/push_models_to_device.sh`.
// ─────────────────────────────────────────────────────────────────────────

import 'dart:io';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:path_provider/path_provider.dart';

class LLMAdapterOptions {
  const LLMAdapterOptions({
    this.systemPrompt = 'You are a helpful on-device AI assistant.',
    this.temperature = 0.3,
    this.maxTokens = 512,
    this.nThreads = 4,
  });
  final String systemPrompt;
  final double temperature;
  final int maxTokens;
  final int nThreads;
}

/// Build the `LLMClient` every sample's `ChatAgent` drives. Swap the
/// first non-commented block to try a different adapter — nothing
/// else in the sample has to change.
///
/// Convenience auto-detection: when the runner sets a cloud-API key
/// (compile-time `--dart-define=ANTHROPIC_API_KEY=...` OR a
/// runtime marker file `/data/local/tmp/dazzle_anthropic_key`), the
/// adapter switches to the matching cloud client. Otherwise it
/// falls through to the on-device default (LlamaCpp / GGUF).
Future<LLMClient> makeLLMClient({
  LLMAdapterOptions options = const LLMAdapterOptions(),
}) async {
  final anthropicKey = await _readKey(
      'ANTHROPIC_API_KEY', '/data/local/tmp/dazzle_anthropic_key');
  if (anthropicKey.isNotEmpty) {
    final model = const String.fromEnvironment('ANTHROPIC_MODEL').isNotEmpty
        ? const String.fromEnvironment('ANTHROPIC_MODEL')
        : 'claude-haiku-4-5-20251001';
    return AnthropicClient.create(
      model:       model,
      apiKey:      anthropicKey,
      maxTokens:   options.maxTokens,
      temperature: options.temperature,
    );
  }
  final openAiKey = await _readKey(
      'OPENAI_API_KEY', '/data/local/tmp/dazzle_openai_key');
  if (openAiKey.isNotEmpty) {
    return OpenAICompatibleClient(
      baseURL:     Uri.parse('https://api.openai.com/v1/'),
      model:       'gpt-4o-mini',
      apiKey:      openAiKey,
      temperature: options.temperature,
      maxTokens:   options.maxTokens,
    );
  }
  final hfToken = await _readKey('HF_TOKEN', '/data/local/tmp/dazzle_hf_token');
  if (hfToken.isNotEmpty) {
    return OpenAICompatibleClient(
      baseURL:     Uri.parse('https://router.huggingface.co/v1/'),
      model:       'meta-llama/Llama-3.3-70B-Instruct',
      apiKey:      hfToken,
      temperature: options.temperature,
      maxTokens:   options.maxTokens,
    );
  }

  // ─── A ─── llama.cpp — any GGUF model (Llama 3, Gemma, Qwen, Phi,
  //                      DeepSeek, Mistral…). Default: Qwen 2.5 1.5B
  //                      Instruct (Q4_K_M).
  final ggufPath = await ModelSetup.qwenGgufPath();
  return LlamaCppClient.create(
    modelPath:    ggufPath,
    systemPrompt: options.systemPrompt,
    temperature:  options.temperature,
    maxTokens:    options.maxTokens,
    nThreads:     options.nThreads,
  );

  // ─── B ─── Google LiteRT-LM (.litertlm) — Android + iOS.
  //          The iOS bridge is our own port: nobody else ships
  //          LiteRT-LM for iOS today.
  //
  // final litertPath = await ModelSetup.gemmaLiteRtPath();
  // return LiteRtLmClient.create(
  //   modelPath:    litertPath,
  //   systemPrompt: options.systemPrompt,
  //   temperature:  options.temperature,
  //   maxTokens:    options.maxTokens,
  // );

  // ─── C ─── Apple Foundation Models (iOS/macOS 26+).
  //          Will throw UnsupportedError on Android — gate with
  //          `await FoundationModelsClient.isAvailable`.
  //
  // if (await FoundationModelsClient.isAvailable) {
  //   return FoundationModelsClient(
  //     systemPrompt: options.systemPrompt,
  //     temperature:  options.temperature,
  //     maxTokens:    options.maxTokens,
  //   );
  // }

  // ─── D ─── OpenAI-compatible endpoint. Supports OpenAI proper,
  //          HuggingFace Inference Router, Ollama, vLLM, Groq,
  //          Together, llama-server, and anything that speaks
  //          `POST /v1/chat/completions` with the same JSON shape.
  //
  // return OpenAICompatibleClient(
  //   baseURL:     Uri.parse('https://api.openai.com/v1/'),
  //   model:       'gpt-4o-mini',
  //   apiKey:      const String.fromEnvironment('OPENAI_API_KEY'),
  //   temperature: options.temperature,
  //   maxTokens:   options.maxTokens,
  // );
  //
  // HuggingFace Router (free tier supports many open-weights LLMs):
  //
  // return OpenAICompatibleClient(
  //   baseURL:     Uri.parse('https://router.huggingface.co/v1/'),
  //   model:       'meta-llama/Llama-3.3-70B-Instruct',
  //   apiKey:      const String.fromEnvironment('HF_TOKEN'),
  //   temperature: options.temperature,
  //   maxTokens:   options.maxTokens,
  // );

  // ─── E ─── Anthropic (Claude) — `/v1/messages` API.
  //
  //   Distinct shape from OpenAI: `system` is top-level, tool use
  //   lives as `content` blocks, schema goes under `input_schema`.
  //   The SDK handles the mapping; this Dart shim calls the native
  //   Kotlin/Swift `AnthropicClient` via MethodChannel/EventChannel
  //   so the same HTTP+SSE code runs whether you're on Android,
  //   iOS, or macOS.
  //
  // return AnthropicClient.create(
  //   model:       'claude-3-5-sonnet-latest',
  //   apiKey:      const String.fromEnvironment('ANTHROPIC_API_KEY'),
  //   maxTokens:   options.maxTokens,
  //   temperature: options.temperature,
  // );
}

// Compile-time `String.fromEnvironment` reads only constfold when
// declared as top-level `const` initialisers. Wrapping them in a
// switch arm doesn't constfold reliably across Dart versions — so we
// hoist them out and pick the right one by name.
const _kAnthropicKeyDefine = String.fromEnvironment('ANTHROPIC_API_KEY');
const _kOpenAIKeyDefine    = String.fromEnvironment('OPENAI_API_KEY');
const _kHFTokenDefine      = String.fromEnvironment('HF_TOKEN');

/// Read an API key from a `--dart-define` (compile-time) first, then
/// fall back to a runtime marker file. The marker-file path is the
/// standard adb-driven smoke convention — `adb push key.txt
/// /data/local/tmp/dazzle_anthropic_key` lets a fresh debug build pick
/// up the key without rebuilding.
Future<String> _readKey(String defineName, String markerPath) async {
  final fromDefine = switch (defineName) {
    'ANTHROPIC_API_KEY' => _kAnthropicKeyDefine,
    'OPENAI_API_KEY'    => _kOpenAIKeyDefine,
    'HF_TOKEN'          => _kHFTokenDefine,
    _ => '',
  };
  if (fromDefine.isNotEmpty) return fromDefine;
  try {
    final f = File(markerPath);
    if (await f.exists()) {
      return (await f.readAsString()).trim();
    }
  } catch (_) {/* iOS / desktop where the path doesn't exist */}
  return '';
}

/// Candidate paths the downloaded model might live at. On Android the
/// default `download_models.sh` push path is `/data/local/tmp/`, which
/// the app sandbox can read. On iOS the model is either bundled as a
/// resource or dropped into the Documents directory by the user.
///
/// For production apps, ship the model inside assets or fetch it with
/// a `ModelDownloader` helper.
class ModelSetup {
  static Future<String> qwenGgufPath() async {
    return _pickExisting(
      'qwen2.5-1.5b-instruct-q4_k_m.gguf',
      hint: 'Push it with:\n'
            '  adb push samples/_scripts/_models/'
            'qwen2.5-1.5b-instruct-q4_k_m.gguf /data/local/tmp/\n'
            'or place it in the app\'s Documents dir.',
    );
  }

  static Future<String> gemmaLiteRtPath() async {
    return _pickExisting(
      'gemma4-e2b-it.litertlm',
      hint: 'Push it with:\n'
            '  adb push samples/_scripts/_models/gemma4-e2b-it.litertlm'
            ' /data/local/tmp/',
    );
  }

  static Future<String> _pickExisting(String filename,
      {required String hint}) async {
    final candidates = <String>[];
    if (Platform.isAndroid) {
      candidates.add('/data/local/tmp/$filename');
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      candidates.add('${docs.path}/$filename');
    } catch (_) {/* web/linux — ignore */}
    try {
      final support = await getApplicationSupportDirectory();
      candidates.add('${support.path}/$filename');
    } catch (_) {/* ignore */}

    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    throw StateError(
        'Model file "$filename" not found on-device.\n$hint');
  }
}
