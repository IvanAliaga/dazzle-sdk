// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// ─────────────────────────────────────────────────────────────────────────
// THE ONE FILE YOU EDIT WHEN YOU WANT A DIFFERENT LLM RUNTIME.
//
// Every Dazzle sample — chat-memory, chat-iot, chat-kb — links against
// this file. The ChatView, the DazzleEdge.chatAgent wiring, and the
// Dazzle storage calls are all identical no matter which adapter you
// pick. That's the whole point of the LLMClient protocol.
//
// Five adapters ship in the SDK:
//
//     A. LlamaCppClient         — any GGUF model, on-device
//     B. LiteRtLmClient         — Google's .litertlm format, on-device
//                                 (we ship the iOS port; nobody else
//                                 has LiteRT-LM running on iPhone)
//     C. FoundationModelsClient — Apple Intelligence, iOS 26+ / macOS 26+
//     D. OpenAICompatibleClient — anything that speaks the OpenAI REST
//                                 shape (OpenAI, HuggingFace Router,
//                                 Ollama, vLLM, Groq, Together, …)
//     E. AnthropicClient        — Anthropic Claude API directly
//                                 (`/v1/messages`, distinct shape from
//                                 OpenAI — `system` field, tool use as
//                                 content blocks, etc.)
//
// Default: LlamaCppClient with Qwen 2.5 1.5B Instruct (Q4_K_M), ~1 GB.
// Download it once with `samples/_scripts/download_models.sh`.
// ─────────────────────────────────────────────────────────────────────────

import Foundation

/// Build the `LLMClient` every sample's ChatAgent drives. Uncomment the
/// adapter you want; comment out the rest.
///
/// Convenience auto-detection: if any of the cloud API-key env vars
/// is set at launch time, switch to the matching cloud adapter
/// without code edits — useful for the smoke runner. Otherwise we
/// fall through to the default (LlamaCpp).
func makeLLMClient() async throws -> any LLMClient {
    let env = ProcessInfo.processInfo.environment
    if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty {
        // ─── E auto ─── Anthropic when ANTHROPIC_API_KEY is in env.
        return AnthropicClient(
            model:     env["ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001",
            apiKey:    key,
            maxTokens: 1024,
            temperature: 0.3)
    }
    if let key = env["OPENAI_API_KEY"], !key.isEmpty {
        return OpenAICompatibleClient(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model:   env["OPENAI_MODEL"] ?? "gpt-4o-mini",
            apiKey:  key,
            temperature: 0.3,
            maxTokens: 512)
    }
    if let key = env["HF_TOKEN"], !key.isEmpty {
        return OpenAICompatibleClient(
            baseURL: URL(string: "https://router.huggingface.co/v1")!,
            model:   env["HF_MODEL"] ?? "meta-llama/Llama-3.3-70B-Instruct",
            apiKey:  key,
            temperature: 0.3,
            maxTokens: 512)
    }

    // ─── A ─── llama.cpp — any GGUF model (Llama 3, Gemma, Qwen, Phi,
    //                       DeepSeek, Mistral, …).
    //          Default: Qwen2.5-1.5B-Instruct-Q4_K_M (fast on A14+).
    //          Download: samples/_scripts/download_models.sh
    return try await LlamaCppClient(
        modelURL: ModelSetup.qwenGgufURL,
        systemPrompt: "You are a helpful on-device AI assistant.",
        temperature: 0.3,
        maxTokens: 512,
        nThreads: 4)

    // ─── B ─── Google LiteRT-LM (.litertlm)
    //          Default: Gemma 4 E2B IT.
    // return try await LiteRtLmClient(
    //     modelURL: ModelSetup.gemmaLiteRtURL,
    //     systemPrompt: "You are a helpful on-device AI assistant.",
    //     temperature: 0.3,
    //     maxTokens: 512)

    // ─── C ─── Apple Intelligence (iOS 26+ / macOS 26+)
    //          Device-side, no downloads, no API keys. Requires
    //          FoundationModels eligibility (Apple silicon 15+, iPhone
    //          15 Pro and later).
    // if #available(iOS 26.0, macOS 26.0, *),
    //    FoundationModelsClient.isAvailable {
    //     return FoundationModelsClient(
    //         systemPrompt: "You are a helpful on-device AI assistant.",
    //         temperature: 0.3,
    //         maxTokens: 512)
    // }

    // ─── D ─── OpenAI-compatible endpoint.
    //
    // Supports: OpenAI proper, HuggingFace Inference Router, Ollama,
    // vLLM, Groq, Together, llama-server, and anything that speaks
    // `POST /v1/chat/completions` with the same JSON shape.
    //
    // Two common configurations — uncomment the one you need and set
    // the matching API key in your environment.
    //
    //   export OPENAI_API_KEY=sk-...
    //   or
    //   export HF_TOKEN=hf_...
    //
    // OpenAI:
    // let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    // return OpenAICompatibleClient(
    //     baseURL: URL(string: "https://api.openai.com/v1")!,
    //     model:   "gpt-4o-mini",
    //     apiKey:  key,
    //     temperature: 0.3,
    //     maxTokens: 512)
    //
    // HuggingFace Router (free tier supports many open-weights LLMs):
    // let key = ProcessInfo.processInfo.environment["HF_TOKEN"] ?? ""
    // return OpenAICompatibleClient(
    //     baseURL: URL(string: "https://router.huggingface.co/v1")!,
    //     model:   "meta-llama/Llama-3.3-70B-Instruct",
    //     apiKey:  key,
    //     temperature: 0.3,
    //     maxTokens: 512)

    // ─── E ─── Anthropic (Claude) — `/v1/messages` API.
    //
    //   Distinct from OpenAI shape: `system` is top-level, tool use
    //   lives as `content` blocks, schema goes under `input_schema`.
    //   The SDK handles the mapping for you.
    //
    // let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    // return AnthropicClient(
    //     model:     "claude-3-5-sonnet-latest",
    //     apiKey:    key,
    //     maxTokens: 1024,
    //     temperature: 0.3)
}

/// Helper: where the downloaded models live inside the app bundle.
///
/// The `_scripts/download_models.sh` script drops the files in
/// `samples/_scripts/_models/` on your Mac. Each sample's Xcode build
/// phase copies them into the .app bundle under `Resources/` so the
/// device can mmap them directly.
enum ModelSetup {
    /// Qwen 2.5 1.5B Instruct, Q4_K_M quantisation. ~1.0 GB.
    static var qwenGgufURL: URL {
        guard let url = Bundle.main.url(
                forResource: "qwen2.5-1.5b-instruct-q4_k_m",
                withExtension: "gguf")
        else {
            fatalError("""
                Qwen GGUF not bundled. Run:
                    samples/_scripts/download_models.sh
                then rebuild the sample.
                """)
        }
        return url
    }

    /// Gemma 4 E2B IT, LiteRT format. ~2.4 GB.
    static var gemmaLiteRtURL: URL {
        guard let url = Bundle.main.url(
                forResource: "gemma4-e2b-it",
                withExtension: "litertlm")
        else {
            fatalError("""
                Gemma LiteRT model not bundled. Run:
                    samples/_scripts/download_models.sh
                then rebuild the sample.
                """)
        }
        return url
    }
}
