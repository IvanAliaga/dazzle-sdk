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

package dev.dazzle.experiment

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.io.File

/**
 * Wraps litertlm-android to run Gemma 4 E2B on-device.
 *
 * Push the model before running:
 *   adb push gemma-4-E2B-it.litertlm /sdcard/Download/
 *
 * On first use the model is copied to internal storage (faster I/O).
 */
class GemmaInference(private val context: Context, modelPath: String) : AutoCloseable {

    private val engine: Engine

    init {
        val internalPath = ensureInternalCopy(modelPath)
        engine = Engine(
            EngineConfig(
                modelPath = internalPath,
                backend   = Backend.CPU(),
                cacheDir  = context.cacheDir.path,
            )
        )
        engine.initialize()
    }

    data class InferenceResult(
        val rawOutput: String,
        val parsedAnswer: String?,
        val promptTokens: Int,
        val inferenceMs: Long,
    )

    /**
     * Low-level inference: accepts a fully-formed user message, runs one
     * ConversationConfig turn, returns the raw string. Used by the
     * Sequential Monitoring Agent pipeline where prompt construction is
     * platform-agnostic (the pipeline builds the user message from the
     * reading + window + optional Valkey context and passes it verbatim so
     * iOS and Android see byte-identical model input).
     */
    fun generateRaw(userMessage: String): InferenceResult {
        val promptTokens = estimateTokens(userMessage)

        val conversationConfig = ConversationConfig(
            systemInstruction = Contents.of(SYSTEM_PROMPT),
            samplerConfig     = SamplerConfig(
                topK        = 1,
                topP        = 1.0,
                temperature = 0.01,
            ),
        )

        val start = System.currentTimeMillis()
        val raw = runBlocking {
            val sb = StringBuilder()
            engine.createConversation(conversationConfig).use { conv ->
                conv.sendMessageAsync(userMessage).collect { chunk ->
                    sb.append(chunk.toString())
                }
            }
            sb.toString().trim()
        }
        val inferenceMs = System.currentTimeMillis() - start

        return InferenceResult(
            rawOutput    = raw,
            parsedAnswer = extractJsonAnswer(raw),
            promptTokens = promptTokens,
            inferenceMs  = inferenceMs,
        )
    }

    /**
     * Run one inference turn.
     *
     * The system instruction is kept separate from the user message so Gemma's
     * internal chat template applies the correct format.
     *
     * @param reading      Current sensor reading.
     * @param questionText Question text (includes JSON format instruction).
     * @param contextBlock Valkey context block (condition B) or null (condition A).
     */
    fun ask(
        reading: SensorReading,
        questionText: String,
        contextBlock: String? = null,
    ): InferenceResult {
        val userMessage  = buildUserMessage(reading, questionText, contextBlock)
        val promptTokens = estimateTokens(userMessage)

        val conversationConfig = ConversationConfig(
            systemInstruction = Contents.of(SYSTEM_PROMPT),
            samplerConfig     = SamplerConfig(
                topK        = 1,
                topP        = 1.0,
                temperature = 0.01,   // near-greedy for reproducibility
            ),
        )

        val start = System.currentTimeMillis()
        val raw = runBlocking {
            val sb = StringBuilder()
            engine.createConversation(conversationConfig).use { conv ->
                conv.sendMessageAsync(userMessage).collect { chunk ->
                    sb.append(chunk.toString())
                }
            }
            sb.toString().trim()
        }
        val inferenceMs = System.currentTimeMillis() - start

        return InferenceResult(
            rawOutput    = raw,
            parsedAnswer = extractJsonAnswer(raw),
            promptTokens = promptTokens,
            inferenceMs  = inferenceMs,
        )
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun buildUserMessage(
        reading: SensorReading,
        question: String,
        contextBlock: String?,
    ): String = buildString {
        if (contextBlock != null) {
            appendLine(contextBlock)
            appendLine()
        }
        appendLine("Current reading:")
        appendLine("  Temperature : ${reading.tempC}°C")
        appendLine("  Humidity    : ${reading.humidity}%")
        appendLine("  Timestamp   : ${reading.timestamp}")
        appendLine()
        append(question)
    }

    private fun extractJsonAnswer(raw: String): String? {
        val start = raw.indexOf('{')
        val end   = raw.lastIndexOf('}')
        if (start == -1 || end == -1 || end <= start) return null
        return try {
            JSONObject(raw.substring(start, end + 1)).opt("answer")?.toString()
        } catch (_: Exception) {
            Regex(""""answer"\s*:\s*"?([^",}\n]+)"?""").find(raw)
                ?.groupValues?.get(1)?.trim()
        }
    }

    /**
     * Copy model from external storage to internal filesDir on first run.
     * Skips copy if destination already exists with matching size, or if
     * source and destination are the same file (model already in internal storage).
     */
    private fun ensureInternalCopy(sourcePath: String): String {
        val src  = File(sourcePath)
        val dest = File(context.filesDir, src.name)
        // Already pointing at internal storage — nothing to copy
        if (src.canonicalPath == dest.canonicalPath) return dest.absolutePath
        if (!dest.exists() || dest.length() != src.length()) {
            src.copyTo(dest, overwrite = true)
        }
        return dest.absolutePath
    }

    private fun estimateTokens(text: String): Int = (text.length / 4).coerceAtLeast(1)

    override fun close() = engine.close()

    companion object {
        // This is the LiteRT systemInstruction turn — the only system-level
        // text Gemma 4 sees. Keep it short: every token here costs on every call.
        // Domain threshold lives here (not in each checkpoint prompt) so the
        // model treats it as a prior rather than a per-call rule, which lets
        // episodic memory override it when evidence is strong.
        // IMPORTANT: do NOT dictate a fixed JSON field name here — the schema
        // is specified per-prompt so checkpoints and synthesis can differ.
        internal const val SYSTEM_PROMPT =
            "You are an edge AI agent monitoring an industrial temperature sensor. " +
            "Fault threshold for this sensor class: temp < 5°C or temp > 28°C. " +
            "When operational memory is provided, use it to calibrate your decision. " +
            "Respond ONLY with the JSON object requested — no markdown fences, no extra text."
    }
}
