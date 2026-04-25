// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatmemory

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import dev.dazzle.samples.shared.ChatScreen
import dev.dazzle.samples.shared.ChatScreenForAgent
import dev.dazzle.samples.shared.LLMAdapter
import dev.dazzle.samples.shared.SampleTestBanner
import dev.dazzle.samples.shared.SampleTestConfig
import dev.dazzle.samples.shared.isSampleTestMode
import dev.dazzle.samples.shared.runSampleTest
import dev.dazzle.sdk.Agent
import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.edge.DazzleEdge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.system.exitProcess

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Headless automated test path — triggered by `adb shell am start
        // -n .../.MainActivity --es SAMPLE_TEST 1`. We still render the
        // ChatScreen bound to the harness's agent so a human watching
        // the device actually sees the scripted conversation play out,
        // not just a blank splash while the JSON quietly passes.
        if (isSampleTestMode(intent.getStringExtra("SAMPLE_TEST"))) {
            setContent {
                MaterialTheme {
                    var agent by remember { mutableStateOf<Agent?>(null) }
                    var phase by remember { mutableStateOf("preparing") }
                    var detail by remember { mutableStateOf<String?>(null) }

                    if (agent != null) {
                        ChatScreenForAgent(
                            title = "chat-memory · test",
                            agent = agent!!,
                            banner = { SampleTestBanner(phase, detail) },
                        )
                    }

                    androidx.compose.runtime.LaunchedEffect(Unit) {
                        val config = SampleTestConfig(
                            sampleName = "chat-memory",
                            // Dev-smoke scripted replies. Real demos
                            // use the LLMAdapter (Qwen) — tap the app
                            // icon normally.
                            llmScript = listOf(
                                Completion.Text(Message(Role.assistant,
                                    "Noted, Ivan. Dazzle — embedded DB with HNSW vector search for on-device LLM agents. I'll keep this context.")),
                                Completion.Text(Message(Role.assistant,
                                    "Yes — you're Ivan Aliaga, working on Dazzle, an embedded database with HNSW vector search for on-device LLM agents. What would you like to do next?")),
                            ),
                            userInputs = listOf(
                                "Hi, I'm Ivan Aliaga. I'm building Dazzle — an embedded database with HNSW vector search for on-device LLM agents. Please remember this.",
                                "Do you remember who I am and what I'm working on?",
                            ),
                            prepare = { /* no-op */ },
                            buildAgent = { llm -> buildAgentWithLLM(llm) },
                            onAgentReady = { agent = it },
                            onStatusChange = { p, d ->
                                phase = p
                                detail = d
                            },
                        )
                        runSampleTest(applicationContext, config)
                        // Small grace period so the JSON fsyncs.
                        kotlinx.coroutines.delay(200)
                        exitProcess(0)
                    }
                }
            }
            return
        }

        setContent {
            MaterialTheme {
                ChatScreen(
                    title = "chat-memory",
                    buildAgent = {
                        withContext(Dispatchers.IO) {
                            buildAgentWithLLM(LLMAdapter.makeLLMClient(applicationContext))
                        }
                    },
                )
            }
        }
    }

    private fun buildAgentWithLLM(llm: LLMClient) =
        DazzleEdge.chatAgent(
            context   = applicationContext,
            llm       = llm,
            threadId  = "chat-memory-default",
        ) {
            systemPrompt = """
                You are Dazzle, a friendly on-device assistant. Keep
                replies short and conversational (1–3 sentences).
            """.trimIndent()
        }
}
