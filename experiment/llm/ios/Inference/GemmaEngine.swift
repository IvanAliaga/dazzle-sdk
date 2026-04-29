// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import LiteRTLMSwift

// ─────────────────────────────────────────────────────────────────────────────
// GemmaEngine
//
// Thin wrapper over LiteRTLM-Swift (community package:
// github.com/mylovelycodes/LiteRTLM-Swift), which ships a pre-built
// CLiteRTLM.xcframework over the official LiteRT-LM C API. This is the SAME
// runtime used by the Android experiment (litertlm-android v0.10.2).
//
// Target model: Gemma 4 E2B (2.41 GB, .litertlm, litert-community)
//   gemma-4-E2B-it.litertlm
//
// Download (HuggingFace, requires Gemma licence acceptance):
//   huggingface-cli download litert-community/gemma-4-E2B-it-litert-lm \
//     gemma-4-E2B-it.litertlm --local-dir ~/Downloads/
// Then transfer to the app's Documents/ folder via
// Xcode → Window → Devices and Simulators → DazzleExperiment.
//
// Memory note: a 2.41 GB model on a 6 GB iPhone requires the
// `com.apple.developer.kernel.increased-memory-limit` entitlement
// (see Sources/Resources/DazzleExperiment.entitlements).
// ─────────────────────────────────────────────────────────────────────────────

enum GemmaError: Error, LocalizedError {
    case modelNotFound(String)
    case notLoaded
    case inferenceError(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Model not found at: \(path)"
        case .notLoaded:               return "Engine not loaded — call warmUp() first"
        case .inferenceError(let e):   return "Inference error: \(e)"
        }
    }
}

final class GemmaEngine {

    static let defaultModelFilename = "gemma-4-E2B-it.litertlm"

    private let engine: LiteRTLMEngine
    private let modelPath: String
    private(set) var isReady = false

    // MARK: - Init

    /// Instantiate the engine. No heavy work yet — call `warmUp()` to load weights.
    /// - Parameter modelPath: Absolute path to a `.litertlm` file.
    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw GemmaError.modelNotFound(modelPath)
        }
        self.modelPath = modelPath
        // CPU backend: matches Android (Backend.CPU()), avoids Metal memory spikes
        // that OOM the 6 GB iPhone 12 Pro when the 2.41 GB model is already resident.
        self.engine = LiteRTLMEngine(
            modelPath: URL(fileURLWithPath: modelPath),
            backend: "cpu"
        )
    }

    // MARK: - Load

    /// Loads the model weights. ~5–10 s on iPhone 12 Pro. Call once.
    func warmUp() async throws {
        do {
            try await engine.load()
            isReady = true
        } catch {
            throw GemmaError.inferenceError(error)
        }
    }

    // MARK: - Inference

    /// One-shot stateless generation. Near-greedy for reproducibility.
    func generate(prompt: String) async throws -> String {
        guard isReady else { throw GemmaError.notLoaded }
        do {
            let raw = try await engine.generate(
                prompt: prompt,
                temperature: Float(0.01),
                maxTokens: 512
            )
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GemmaError.inferenceError(error)
        }
    }

    /// Streaming variant — token-by-token via an AsyncThrowingStream from
    /// `engine.generateStreaming`. Accumulates the full response and reports it
    /// via `completion` once the stream finishes.
    func generateStreaming(
        prompt: String,
        chunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isReady else {
            completion(.failure(GemmaError.notLoaded))
            return
        }
        Task {
            var accumulated = ""
            do {
                for try await token in engine.generateStreaming(
                    prompt: prompt,
                    temperature: Float(0.01),
                    maxTokens: 512
                ) {
                    accumulated += token
                    chunk(token)
                }
                completion(.success(accumulated.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                completion(.failure(GemmaError.inferenceError(error)))
            }
        }
    }

    // MARK: - Prompt helpers

    // Domain threshold lives here (not in each checkpoint prompt) so the model
    // treats it as a prior. Do NOT dictate a fixed JSON field name — the schema
    // is specified per-prompt so checkpoints and synthesis can differ.
    static let systemInstruction =
        "You are an edge AI agent monitoring an industrial temperature sensor. " +
        "Fault threshold for this sensor class: temp < 5°C or temp > 28°C. " +
        "When operational memory is provided, use it to calibrate your decision. " +
        "Respond ONLY with the JSON object requested — no markdown fences, no extra text."

    /// Build a Gemma-4 chat-turn prompt.
    /// System instruction goes in its own turn so it is treated as a prior,
    /// not as part of the user question. Context (if any) and the question
    /// form the user turn.
    static func buildPrompt(context: String? = nil, question: String) -> String {
        var userBody = ""
        if let ctx = context, !ctx.isEmpty {
            userBody += ctx + "\n\n"
        }
        userBody += question
        return "<|turn>system\n\(systemInstruction)\n<turn|>\n<|turn>user\n\(userBody)\n<turn|>\n<|turn>model\n"
    }
}
