// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// ────────────────────────────────────────────────────────────────────
//  DEV SMOKE HARNESS — this is NOT the product.
// ────────────────────────────────────────────────────────────────────
//
// Fast (<10 s/sample) cross-platform CI verification. Wires a
// `FakeLLMClient` with scripted replies so the pass/fail doesn't
// depend on an on-device GGUF being loaded — only on the wiring:
// Activity boots, Dazzle starts, corpus loads, tool loop fires,
// agent persists messages, report JSON emits. Runs behind the
// `SAMPLE_TEST=1` intent extra; the normal app launch (tap the app
// icon) skips this entirely and uses the real on-device LLM from
// `LLMAdapter.kt` — that path is the actual product.
//
// The on-screen banner stamped by the SampleTestBanner composable
// makes the distinction explicit so nobody confuses the smoke run
// with the production chat.
//
// Matches samples/_shared/ios/SampleTestRunner.swift one-to-one so
// the cross-platform test produces the same report shape.

package dev.dazzle.samples.shared

import android.content.Context
import android.os.Environment
import dev.dazzle.sdk.Agent
import dev.dazzle.sdk.AgentStatus
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.DazzleServer
import dev.dazzle.sdk.FakeLLMClient
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Role
import kotlinx.coroutines.delay
import java.io.File

data class SampleTestConfig(
    val sampleName: String,
    /** Pre-scripted assistant completions the FakeLLMClient replays
     *  in order. See `FakeLLMClient`'s contract. */
    val llmScript: List<Completion>,
    /** The question(s) the harness types in on the user's behalf. */
    val userInputs: List<String>,
    val prepare: suspend () -> Unit,
    /** Build the ChatAgent — receives the FakeLLMClient the harness
     *  constructs; the closure wires the same tools + system prompt
     *  the production app uses. */
    val buildAgent: suspend (LLMClient) -> Agent,

    val onAgentReady: ((Agent) -> Unit)? = null,
    val onStatusChange: ((phase: String, detail: String?) -> Unit)? = null,

    val delayBetweenTurnsMs: Long = 1_200L,
    val postRunDisplayMs: Long = 5_000L,
)

data class TestReport(
    val sampleName: String,
    val elapsedMs: Long,
    val turnCount: Int,
    val userTurns: Int,
    val assistantTurns: Int,
    val toolTurns: Int,
    val llmCallCount: Int,
    val lastAssistantText: String,
    val lastToolText: String,
    val status: String,
    val error: String? = null,
)

/**
 * Drives the scripted flow and writes the JSON report. Call from the
 * Activity's `onCreate` (not a Composable) so the lifecycle stays
 * predictable.
 */
suspend fun runSampleTest(context: Context, config: SampleTestConfig): Boolean {
    val start = System.currentTimeMillis()
    val fake = FakeLLMClient(script = config.llmScript)
    var agent: Agent? = null

    return try {
        config.onStatusChange?.invoke("preparing", null)

        if (!DazzleServer.isRunning()) {
            DazzleServer.start(context, DazzleServer.config)
        }

        config.prepare()
        val realMarker = java.io.File("/data/local/tmp/dazzle_real_llm")
        val llm: LLMClient = if (realMarker.exists()) {
            android.util.Log.i("SampleTestRunner",
                "real-LLM marker present → using LLMAdapter")
            try {
                LLMAdapter.makeLLMClient(context)
            } catch (t: Throwable) {
                android.util.Log.e("SampleTestRunner",
                    "LLMAdapter.makeLLMClient failed: ${t.message}", t)
                throw t
            }
        } else {
            fake
        }
        agent = config.buildAgent(llm)
        config.onAgentReady?.invoke(agent)

        delay(400)
        config.onStatusChange?.invoke("running", null)

        // Real LLMs (esp. cloud routers) can take 10–60 s/turn for
        // multi-token replies. Fake is instant; either way 90 s
        // covers it without hanging CI when the network drops.
        val perTurnTimeoutMs = if (realMarker.exists()) 90_000L else 30_000L
        for ((i, input) in config.userInputs.withIndex()) {
            if (i > 0) delay(config.delayBetweenTurnsMs)
            agent.send(input)
            val deadline = System.currentTimeMillis() + perTurnTimeoutMs
            while (agent.status.value != AgentStatus.Idle) {
                if (System.currentTimeMillis() > deadline) {
                    throw RuntimeException(
                        "turn '$input' timed out after " +
                        "${perTurnTimeoutMs / 1000} s")
                }
                delay(100)
            }
        }

        val messages = agent.messages.value
        val assistantTurns = messages.filter { it.role == Role.assistant }
        val toolTurns = messages.filter { it.role == Role.tool }

        val elapsed = System.currentTimeMillis() - start
        config.onStatusChange?.invoke(
            "completed", "${messages.size} turns · $elapsed ms"
        )

        delay(config.postRunDisplayMs)

        writeReport(context, TestReport(
            sampleName = config.sampleName,
            elapsedMs  = System.currentTimeMillis() - start,
            turnCount  = messages.size,
            userTurns  = messages.count { it.role == Role.user },
            assistantTurns = assistantTurns.size,
            toolTurns  = toolTurns.size,
            llmCallCount = fake.callCount,
            lastAssistantText = assistantTurns.lastOrNull()?.text ?: "",
            lastToolText      = toolTurns.lastOrNull()?.text ?: "",
            status = "pass",
            error  = null,
        ))
        writeMarker(context, ok = true, message = "sample_test_${config.sampleName}")
        true
    } catch (t: Throwable) {
        config.onStatusChange?.invoke("failed",
            "${t::class.simpleName}: ${t.message}")
        delay(2_000)
        writeReport(context, TestReport(
            sampleName = config.sampleName,
            elapsedMs  = System.currentTimeMillis() - start,
            turnCount = 0, userTurns = 0, assistantTurns = 0, toolTurns = 0,
            llmCallCount = 0,
            lastAssistantText = "", lastToolText = "",
            status = "fail",
            error  = "${t::class.simpleName}: ${t.message}",
        ))
        writeMarker(context, ok = false, message = "sample_test_${config.sampleName}")
        false
    }
}

/**
 * Convenience: check the intent extras / system property for the
 * SAMPLE_TEST flag. Activities read this from
 * `intent.getStringExtra("SAMPLE_TEST")`.
 */
fun isSampleTestMode(intentExtra: String?): Boolean {
    return intentExtra == "1"
        || System.getProperty("dazzle.sample_test") == "1"
}

// ─────────────────────────────────────────────────────────────────
// Storage note (Android version matrix):
//
//   API 21–29 (Android 5–10):
//       /sdcard/Documents works with WRITE_EXTERNAL_STORAGE +
//       requestLegacyExternalStorage=true in the manifest.
//
//   API 30+ (Android 11+):
//       Scoped storage — /sdcard/Documents blocked for File I/O
//       unless the app holds MANAGE_EXTERNAL_STORAGE (Google Play
//       will REJECT most apps that request it). MediaStore is the
//       sanctioned path but overkill for a dev harness.
//
//   API 33+ (Android 13+):
//       Further tightened. `File.writeText("/sdcard/Documents/…")`
//       fails with EACCES even when the file already exists,
//       depending on the owning UID.
//
//   app-private `context.filesDir` (what we use):
//       Works IDENTICALLY on every Android version from API 21 to
//       35+. No permissions. No MediaStore. The harness shell reads
//       it back via `adb shell run-as <pkg> cat files/…`, which is
//       guaranteed to work on debug-signed builds.
//
// Devs who ship a real app and want user-visible files should use
// getExternalFilesDir() (no permissions, cleared on uninstall) or
// MediaStore Downloads. NEVER /sdcard/Documents direct.
// ─────────────────────────────────────────────────────────────────
private fun writeReport(context: Context, report: TestReport) {
    val file = File(context.filesDir, "sample_test_${report.sampleName}.json")
    // Hand-rolled JSON to avoid pulling kotlinx.serialization into samples
    // that don't already need it (chat-memory has no bundled datasets).
    file.writeText(report.toJson())
}

private fun TestReport.toJson(): String {
    val sb = StringBuilder()
    sb.append("{\n")
    sb.append("  \"sample_name\": \"${sampleName.jsonEscape()}\",\n")
    sb.append("  \"elapsed_ms\": $elapsedMs,\n")
    sb.append("  \"turn_count\": $turnCount,\n")
    sb.append("  \"user_turns\": $userTurns,\n")
    sb.append("  \"assistant_turns\": $assistantTurns,\n")
    sb.append("  \"tool_turns\": $toolTurns,\n")
    sb.append("  \"llm_call_count\": $llmCallCount,\n")
    sb.append("  \"last_assistant_text\": \"${lastAssistantText.jsonEscape()}\",\n")
    sb.append("  \"last_tool_text\": \"${lastToolText.jsonEscape()}\",\n")
    sb.append("  \"status\": \"${status.jsonEscape()}\",\n")
    sb.append("  \"error\": ")
    if (error == null) sb.append("null\n") else sb.append("\"${error.jsonEscape()}\"\n")
    sb.append("}\n")
    return sb.toString()
}

private fun String.jsonEscape(): String = this
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
    .replace("\n", "\\n")
    .replace("\r", "\\r")
    .replace("\t", "\\t")

private fun writeMarker(context: Context, ok: Boolean, message: String) {
    // filesDir (app-private) — see writeReport for rationale.
    val file = File(context.filesDir, "experiment_backends_complete.marker")
    file.writeText("${System.currentTimeMillis()} " +
                    "${if (ok) "ok" else "error"} $message\n")
}
