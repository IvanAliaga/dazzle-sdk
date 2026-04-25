// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.samples.chatiot

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
                            title = "chat-iot · test",
                            agent = agent!!,
                            banner = { SampleTestBanner(phase, detail) },
                        )
                    }

                    LaunchedEffect(Unit) {
                        val config = SampleTestConfig(
                            sampleName = "chat-iot",
                            // Dev-smoke scripted replies. Real demos
                            // use the LLMAdapter (Qwen).
                            llmScript = listOf(
                                Completion.ToolCalls(Message(
                                    role = Role.assistant, content = "",
                                    toolCalls = listOf(ToolCall(
                                        id = "c1",
                                        name = "retrieve_anomalies",
                                        arguments = """{"min_from":0,"min_to":800}""",
                                    )),
                                )),
                                Completion.Text(Message(Role.assistant,
                                    "I found one thermal anomaly in the first 800 minutes: a brief temperature spike to 28.5°C around minute 195, lasting about 3 minutes. Outside that window the sensors stayed stable, averaging 22.1°C with humidity near 48%. The spike pattern is consistent with an interrupted ventilation cycle.")),
                            ),
                            userInputs = listOf("Run an analysis on the sensor data covering the first 800 minutes of the day. Tell me whether there were any thermal anomalies, when they happened, and how the rest of the window behaved."),
                            prepare = {
                                withContext(Dispatchers.IO) {
                                    IotCorpus.loadIntoDazzle(applicationContext)
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
                    title = "chat-iot",
                    buildAgent = {
                        withContext(Dispatchers.IO) {
                            // Dazzle must be up before the corpus loader
                            // runs its first primitive call — otherwise
                            // `DEL samples:iot:windows` throws "server
                            // down". `DazzleEdge.chatAgent` boots it
                            // lazily, but we hit Dazzle BEFORE that.
                            if (!dev.dazzle.sdk.DazzleServer.isRunning()) {
                                dev.dazzle.sdk.DazzleServer.start(
                                    applicationContext,
                                    dev.dazzle.sdk.DazzleConfig()
                                )
                            }
                            IotCorpus.loadIntoDazzle(applicationContext)
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
            threadId  = "chat-iot-default",
        ) {
            systemPrompt = """
                You are a sensor-data analyst running entirely on-device
                against the user's local Dazzle store. When the user
                asks about temperature, humidity, anomalies, or a
                specific time window, call the retrieve_anomalies tool
                with the minute range (dataset minute 0..2399). Use the
                tool's JSON output to ground your answer — do NOT
                invent numbers. Keep replies concise (2–4 sentences).
            """.trimIndent()
            tools.add(RetrieveAnomaliesTool())
        }
}
