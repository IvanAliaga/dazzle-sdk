// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// ─────────────────────────────────────────────────────────────────────────
// THE ONE FILE YOU EDIT WHEN YOU WANT A DIFFERENT LLM RUNTIME.
//
// Every Dazzle sample — chat-memory, chat-iot, chat-kb — links against
// this file. The ChatScreen, the DazzleEdge.chatAgent wiring, and the
// Dazzle storage calls are all identical no matter which adapter you
// pick. That's the whole point of the LLMClient interface.
//
// Five adapters ship in the SDK:
//
//     A. LlamaCppClient         — any GGUF model, on-device
//     B. LiteRtLmClient         — Google's .litertlm format, on-device
//                                 (Android + iOS — the iOS bridge is
//                                 our own port; nobody else ships
//                                 LiteRT-LM for iOS today)
//     C. FoundationModelsClient — iOS-only. Not applicable on Android.
//     D. OpenAICompatibleClient — anything that speaks the OpenAI REST
//                                 shape (OpenAI, HuggingFace Router,
//                                 Ollama, vLLM, Groq, Together, …)
//     E. AnthropicClient        — Anthropic Claude API directly
//                                 (`/v1/messages`, distinct shape
//                                 from OpenAI — `system` field, tool
//                                 use as content blocks, etc.)
//
// Default: LlamaCppClient with Qwen 2.5 1.5B Instruct (Q4_K_M), ~1 GB.
// Run `samples/_scripts/download_models.sh` once to fetch the weights
// and `push_models_to_device.sh` to push them to /data/local/tmp on the
// device. See each sample's README for the setup.
// ─────────────────────────────────────────────────────────────────────────

package dev.dazzle.samples.shared

import android.content.Context
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.edge.AnthropicClient
import dev.dazzle.sdk.edge.LiteRtLmClient
import dev.dazzle.sdk.edge.LlamaCppClient
import dev.dazzle.sdk.edge.OpenAICompatibleClient
import java.io.File

object LLMAdapter {

    /// Build the `LLMClient` every sample's ChatAgent drives. Uncomment
    /// the adapter you want; comment out the rest.
    fun makeLLMClient(context: Context): LLMClient {

        // ─── A ─── llama.cpp — any GGUF model (Llama 3, Gemma, Qwen,
        //                       Phi, DeepSeek, Mistral, …).
        //          Default: Qwen 2.5 0.5B Instruct Q4_K_M (~400 MB).
        //
        // The 1.5B variant (~1 GB) produces better prose but is too
        // slow on mid-tier devices (e.g. Moto G35 takes 2–3 min per
        // turn). The 0.5B fits the "fast on phone" bucket the paper
        // targets and still grounds answers correctly once Dazzle
        // hands it the retrieved rows. Swap the path below if you
        // want the 1.5B — `ModelSetup.qwen15GgufFile(context)`.
        return LlamaCppClient(
            modelFile = ModelSetup.qwenGgufFile(context),
            systemPrompt = "You are a helpful on-device AI assistant.",
            temperature = 0.3f,
            maxTokens = 192,
            nThreads = 4,
        )

        // ─── B ─── Google LiteRT-LM (.litertlm)
        //          Default: Gemma 4 E2B IT.
        // return LiteRtLmClient(
        //     modelFile = ModelSetup.gemmaLiteRtFile(context),
        //     context = context,
        //     systemPrompt = "You are a helpful on-device AI assistant.",
        //     temperature = 0.3,
        //     maxTokens = 512,
        // )

        // ─── D ─── OpenAI-compatible endpoint.
        //
        // Supports: OpenAI proper, HuggingFace Inference Router, Ollama,
        // vLLM, Groq, Together, llama-server, and anything that speaks
        // `POST /v1/chat/completions` with the same JSON shape.
        //
        // Reads the key from a system property so you don't have to
        // wire BuildConfig:  `-Pdazzle.openai_key=sk-...` on the gradle
        // command line, or set it from your IDE run config. Empty key
        // is fine for endpoints that don't authenticate (Ollama,
        // llama-server, local vLLM).
        //
        // OpenAI:
        // return OpenAICompatibleClient(
        //     baseURL  = "https://api.openai.com/v1",
        //     model    = "gpt-4o-mini",
        //     apiKey   = System.getProperty("dazzle.openai_key", ""),
        //     temperature = 0.3,
        //     maxTokens   = 512,
        // )
        //
        // HuggingFace Router (free tier supports many open-weights LLMs):
        // return OpenAICompatibleClient(
        //     baseURL  = "https://router.huggingface.co/v1",
        //     model    = "meta-llama/Llama-3.3-70B-Instruct",
        //     apiKey   = System.getProperty("dazzle.hf_token", ""),
        //     temperature = 0.3,
        //     maxTokens   = 512,
        // )

        // ─── E ─── Anthropic (Claude) — `/v1/messages` API.
        //
        //   Distinct from OpenAI shape: `system` is top-level, tool
        //   use lives as `content` blocks, schema goes under
        //   `input_schema`. The SDK handles the mapping for you.
        //
        // return AnthropicClient(
        //     model     = "claude-3-5-sonnet-latest",
        //     apiKey    = System.getProperty("dazzle.anthropic_key", ""),
        //     maxTokens = 1024,
        //     temperature = 0.3,
        // )
    }
}

/// Helper: where the downloaded model files live on device.
///
/// `samples/_scripts/download_models.sh` drops them on your Mac; the
/// push step copies them to `/data/local/tmp/` on the connected device
/// (adb pushes need an unlocked device + USB debugging). The path is
/// readable by the app sandbox because `/data/local/tmp/` is granted
/// read access via the manifest's requestLegacyExternalStorage.
/// For production apps, ship the model inside assets or download it
/// through `ModelDownloader`.
object ModelSetup {

    /// Default: Qwen 2.5 0.5B Instruct Q4_K_M — ~400 MB, fast on
    /// mid-tier devices. Pulled from
    ///   HuggingFace: Qwen/Qwen2.5-0.5B-Instruct-GGUF
    /// Path ordering: pushed-by-adb first, then per-app files dir.
    fun qwenGgufFile(context: Context): File {
        val candidates = listOf(
            File("/data/local/tmp/qwen2.5-0.5b-instruct-q4_k_m.gguf"),
            File(context.filesDir, "qwen2.5-0.5b-instruct-q4_k_m.gguf"),
            File(context.getExternalFilesDir(null),
                 "qwen2.5-0.5b-instruct-q4_k_m.gguf"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error(
                "Qwen GGUF not found. Push it with:\n" +
                "  adb push samples/_scripts/_models/" +
                "qwen2.5-0.5b-instruct-q4_k_m.gguf /data/local/tmp/\n" +
                "or place it in the app's files dir."
            )
    }

    /// Larger variant (1.5B, ~1 GB). Better prose but slow on mid-tier
    /// devices — use when the target is flagships with >6 GB RAM.
    fun qwen15GgufFile(context: Context): File {
        val candidates = listOf(
            File("/data/local/tmp/qwen2.5-1.5b-instruct-q4_k_m.gguf"),
            File(context.filesDir, "qwen2.5-1.5b-instruct-q4_k_m.gguf"),
            File(context.getExternalFilesDir(null),
                 "qwen2.5-1.5b-instruct-q4_k_m.gguf"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error(
                "Qwen 1.5B GGUF not found. Push it with:\n" +
                "  adb push samples/_scripts/_models/" +
                "qwen2.5-1.5b-instruct-q4_k_m.gguf /data/local/tmp/\n" +
                "or use the 0.5B variant (faster on mid-tier phones)."
            )
    }

    fun gemmaLiteRtFile(context: Context): File {
        val candidates = listOf(
            File("/data/local/tmp/gemma4-e2b-it.litertlm"),
            File(context.filesDir, "gemma4-e2b-it.litertlm"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error(
                "Gemma LiteRT model not found. Push it with:\n" +
                "  adb push samples/_scripts/_models/gemma4-e2b-it.litertlm" +
                " /data/local/tmp/"
            )
    }
}
