// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatkb

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.LaunchedEffect
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
import dev.dazzle.sdk.ToolCall
import dev.dazzle.sdk.edge.DazzleEdge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.system.exitProcess

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (isSampleTestMode(intent.getStringExtra("SAMPLE_TEST"))) {
            setContent {
                MaterialTheme {
                    var agent by remember { mutableStateOf<Agent?>(null) }
                    var phase by remember { mutableStateOf("preparing") }
                    var detail by remember { mutableStateOf<String?>(null) }

                    if (agent != null) {
                        ChatScreenForAgent(
                            title = "chat-kb · test",
                            agent = agent!!,
                            banner = { SampleTestBanner(phase, detail) },
                        )
                    }

                    LaunchedEffect(Unit) {
                        val config = SampleTestConfig(
                            sampleName = "chat-kb",
                            // Dev-smoke scripted replies. Real demos
                            // use the LLMAdapter (Qwen).
                            llmScript = listOf(
                                Completion.ToolCalls(Message(
                                    role = Role.assistant, content = "",
                                    toolCalls = listOf(ToolCall(
                                        id = "c1",
                                        name = "search_kb",
                                        arguments = """{"query":"HNSW_SQ8 vs sqlite-vec mobile latency memory benchmark","k":5}""",
                                    )),
                                )),
                                Completion.Text(Message(Role.assistant,
                                    "Dazzle uses HNSW_SQ8 — a proximity-graph index with 8-bit scalar quantization. On a Moto G35 benchmark with 10k × 384-d vectors, Dazzle runs queries in about 2.3 ms versus ~180 ms for sqlite-vec, which does a linear brute-force scan. The quantized index is also around 4× smaller than F32 — roughly 40 MB vs 160 MB for the same corpus — which matters on mid-tier devices where RAM is tight.")),
                            ),
                            userInputs = listOf("Explain how Dazzle handles vector search on mobile and how it compares to sqlite-vec in terms of query latency and memory footprint."),
                            prepare = {
                                withContext(Dispatchers.IO) {
                                    KbCorpus.loadIntoDazzle(applicationContext)
                                }
                            },
                            buildAgent = { llm -> buildAgentWithLLM(llm) },
                            onAgentReady = { agent = it },
                            onStatusChange = { p, d ->
                                phase = p
                                detail = d
                            },
                        )
                        runSampleTest(applicationContext, config)
                        delay(200)
                        exitProcess(0)
                    }
                }
            }
            return
        }

        setContent {
            MaterialTheme {
                ChatScreen(
                    title = "chat-kb",
                    buildAgent = {
                        withContext(Dispatchers.IO) {
                            // Dazzle must be up before the corpus loader
                            // hits it for the first primitive call.
                            if (!dev.dazzle.sdk.DazzleServer.isRunning()) {
                                dev.dazzle.sdk.DazzleServer.start(
                                    applicationContext,
                                    dev.dazzle.sdk.DazzleConfig()
                                )
                            }
                            KbCorpus.loadIntoDazzle(applicationContext)
                            buildAgentWithLLM(
                                LLMAdapter.makeLLMClient(applicationContext))
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
            threadId  = "chat-kb-default",
        ) {
            systemPrompt = """
                You are a Dazzle-SDK support assistant running entirely
                on-device. For ANY question about Dazzle, HNSW,
                sqlite-vec, sqlite-vector-ai, the four LLM adapters, or
                the benchmarks, call search_kb(query, k=5) first and
                ground your answer in the returned FAQ rows. If the
                question is clearly not about Dazzle, answer directly.
                Keep replies concise (2–4 sentences).
            """.trimIndent()
            tools.add(SearchKbTool())
        }
}
