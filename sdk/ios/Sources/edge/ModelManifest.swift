// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// Pinned catalog of LLM weight files that the Layer 3 `DazzleEdge`
/// bundle knows how to download. Mirror of the Android `ModelManifest.kt`
/// and the shared `docs/sdk/edge_models.json` — all three must agree.
public enum ModelManifest {

    public struct Entry: Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let filename: String
        public let url: URL
        public let sha256: String
        public let sizeBytes: Int64
        public let backend: Backend
        public let version: String

        public init(
            id: String,
            displayName: String,
            filename: String,
            url: URL,
            sha256: String,
            sizeBytes: Int64,
            backend: Backend,
            version: String
        ) {
            self.id = id
            self.displayName = displayName
            self.filename = filename
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.backend = backend
            self.version = version
        }
    }

    public enum Backend: String, Sendable, Equatable {
        case liteRTLM, llamaCpp
    }

    /// Gemma 4 E2B Instruction-Tuned — 2.41 GB. Default bundled model.
    public static let gemma4_E2B = Entry(
        id: "gemma-4-E2B-it",
        displayName: "Gemma 4 E2B Instruction-Tuned",
        filename: "gemma-4-E2B-it.litertlm",
        url: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it/resolve/main/gemma-4-E2B-it.litertlm")!,
        sha256: "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD",
        sizeBytes: 2_584_948_736,
        backend: .liteRTLM,
        version: "1.0.0"
    )

    /// Llama 3.2 3B Instruct — 1.50 GB — slimmer alternative.
    public static let llama32_3B = Entry(
        id: "llama-3.2-3B-instruct",
        displayName: "Llama 3.2 3B Instruct",
        filename: "llama-3.2-3b-instruct.litertlm",
        url: URL(string: "https://huggingface.co/litert-community/Llama-3.2-3B-Instruct/resolve/main/llama-3.2-3b-instruct.litertlm")!,
        sha256: "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD",
        sizeBytes: 1_610_612_736,
        backend: .liteRTLM,
        version: "1.0.0"
    )

    /// Qwen 2.5 1.5B Instruct — 0.90 GB — smallest shipped model.
    public static let qwen25_1B5B = Entry(
        id: "qwen-2.5-1.5b-instruct",
        displayName: "Qwen 2.5 1.5B Instruct",
        filename: "qwen-2.5-1.5b-instruct.litertlm",
        url: URL(string: "https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/qwen-2.5-1.5b-instruct.litertlm")!,
        sha256: "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD",
        sizeBytes: 966_367_641,
        backend: .liteRTLM,
        version: "1.0.0"
    )

    /// Every known entry. Order matches `docs/sdk/edge_models.json`.
    public static let all: [Entry] = [gemma4_E2B, llama32_3B, qwen25_1B5B]
}
