// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

/**
 * Pinned catalog of LLM weight files that the Layer 3 `DazzleEdge`
 * bundle knows how to download. The full manifest lives in
 * `docs/sdk/edge_models.json`; this file is the Kotlin projection
 * consumers reference at compile time.
 *
 * When you bump a pinned SHA or add a new model, update BOTH this
 * file and the Swift equivalent (`ModelManifest.swift`) AND the
 * shared JSON. The API_CONTRACT treats those three as a single
 * source of truth — divergence = bug.
 */
object ModelManifest {

    /** One entry per known model. */
    data class Entry(
        val id: String,
        val displayName: String,
        val filename: String,
        val url: String,
        val sha256: String,
        val sizeBytes: Long,
        val backend: Backend,
        val version: String,
    )

    enum class Backend { LiteRTLM, LlamaCpp }

    /** Gemma 4 E2B Instruction-Tuned — 2.41 GB — the default bundled
     *  model. Same artifact used across the research experiments. */
    val gemma4_E2B: Entry = Entry(
        id = "gemma-4-E2B-it",
        displayName = "Gemma 4 E2B Instruction-Tuned",
        filename = "gemma-4-E2B-it.litertlm",
        url = "https://huggingface.co/litert-community/gemma-4-E2B-it/resolve/main/gemma-4-E2B-it.litertlm",
        sha256 = "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD",
        sizeBytes = 2_584_948_736L,
        backend = Backend.LiteRTLM,
        version = "1.0.0",
    )

    /** Llama 3.2 3B Instruct — 1.50 GB — slimmer alternative. */
    val llama32_3B: Entry = Entry(
        id = "llama-3.2-3B-instruct",
        displayName = "Llama 3.2 3B Instruct",
        filename = "llama-3.2-3b-instruct.litertlm",
        url = "https://huggingface.co/litert-community/Llama-3.2-3B-Instruct/resolve/main/llama-3.2-3b-instruct.litertlm",
        sha256 = "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD",
        sizeBytes = 1_610_612_736L,
        backend = Backend.LiteRTLM,
        version = "1.0.0",
    )

    /** Qwen 2.5 1.5B Instruct — 0.90 GB — smallest shipped model. */
    val qwen25_1B5B: Entry = Entry(
        id = "qwen-2.5-1.5b-instruct",
        displayName = "Qwen 2.5 1.5B Instruct",
        filename = "qwen-2.5-1.5b-instruct.litertlm",
        url = "https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/qwen-2.5-1.5b-instruct.litertlm",
        sha256 = "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD",
        sizeBytes = 966_367_641L,
        backend = Backend.LiteRTLM,
        version = "1.0.0",
    )

    /** Every known entry. Order matches the `docs/sdk/edge_models.json`
     *  file so manifest diffs stay readable. */
    val all: List<Entry> = listOf(gemma4_E2B, llama32_3B, qwen25_1B5B)
}
