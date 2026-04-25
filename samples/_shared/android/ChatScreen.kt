// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// Shared Compose chat screen. Every Dazzle sample references this file
// via its `build.gradle.kts` so the chat UX is identical across
// chat-memory, chat-iot, and chat-kb.

package dev.dazzle.samples.shared

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dazzle.sdk.Agent
import dev.dazzle.sdk.AgentStatus
import dev.dazzle.sdk.ChatTurn
import dev.dazzle.sdk.Role
import kotlinx.coroutines.launch

/**
 * Generic Compose chat screen. The sample owns the agent factory
 * (`buildAgent`) which injects its own tools / system prompt; this
 * screen handles scroll, input, streaming dots, tool-call pills, and
 * error surfacing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    title: String,
    buildAgent: suspend () -> Agent,
    banner: (@Composable () -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    var agent by remember { mutableStateOf<Agent?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        if (agent != null) return@LaunchedEffect
        try {
            agent = buildAgent()
        } catch (t: Throwable) {
            // Surface the full stack to logcat so `adb logcat` shows
            // exactly what blew up — otherwise the UI banner is the
            // only clue and you have to guess.
            android.util.Log.e(
                "ChatScreen",
                "buildAgent failed: ${t.message}",
                t
            )
            errorMessage = "${t::class.simpleName}: ${t.message}"
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            )
        }
    ) { padding ->
        Surface(modifier = Modifier.padding(padding).fillMaxSize()) {
            val a = agent
            if (a != null) {
                Column(Modifier.fillMaxSize()) {
                    banner?.invoke()
                    ChatBody(agent = a)
                }
            } else if (errorMessage != null) {
                ErrorBanner(errorMessage!!)
            } else {
                LoadingStub()
            }
        }
    }
}

/**
 * Variant used by the sample-test harness (`runSampleTest`). Instead
 * of constructing its own agent, the caller hands in an `Agent` the
 * test harness already built around a `FakeLLMClient` — and the
 * ChatScreen reactively renders the scripted conversation as it
 * plays out. Makes the automated run visually verifiable on-device.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreenForAgent(
    title: String,
    agent: Agent,
    banner: (@Composable () -> Unit)? = null,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            )
        }
    ) { padding ->
        Surface(modifier = Modifier.padding(padding).fillMaxSize()) {
            Column(Modifier.fillMaxSize()) {
                banner?.invoke()
                ChatBody(agent = agent)
            }
        }
    }
}

@Composable
private fun ChatBody(agent: Agent) {
    val scope = rememberCoroutineScope()
    val messages by agent.messages.collectAsStateWithLifecycle()
    val streaming by agent.streaming.collectAsStateWithLifecycle()
    val status by agent.status.collectAsStateWithLifecycle()
    var input by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // Auto-scroll when new message or streaming update arrives.
    LaunchedEffect(messages.size, streaming?.text) {
        val idx = messages.size + (if (streaming != null) 1 else 0) - 1
        if (idx >= 0) listState.animateScrollToItem(idx)
    }

    Column(Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.weight(1f),
        ) {
            // Hide raw tool-JSON bubbles and empty assistant
            // envelopes — those are internal LLM context, not
            // user-facing messages. Stand in for each tool
            // round-trip with a compact "called <tool>" pill.
            // Index-prefixed keys so we never collide even when
            // two turns share an id (e.g. a freshly-restored
            // conversation can reuse sentinel ids).
            messages.forEachIndexed { i, turn ->
                when {
                    turn.role == Role.tool -> Unit
                    turn.role == Role.assistant && turn.text.isEmpty() -> {
                        val nextTool = messages
                            .drop(i + 1)
                            .firstOrNull { it.role == Role.tool }
                        if (nextTool != null) {
                            val toolName = turn.toolCalls.firstOrNull()?.name
                                ?: "tool"
                            item("pill-$i-${turn.id}") { ToolPill(toolName) }
                        }
                    }
                    else -> item("m-$i-${turn.id}") { MessageBubble(turn) }
                }
            }
            streaming?.let { s ->
                item("__streaming__") { StreamingBubble(s.text, s.activeTool) }
            }
        }

        Row(
            Modifier.fillMaxWidth().padding(12.dp).imePadding(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = input,
                onValueChange = { input = it },
                placeholder = { Text("Ask Dazzle…") },
                modifier = Modifier.weight(1f),
                enabled = status == AgentStatus.Idle,
            )
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = {
                    if (status != AgentStatus.Idle) {
                        agent.cancel()
                        return@IconButton
                    }
                    val text = input.trim()
                    if (text.isEmpty()) return@IconButton
                    scope.launch {
                        input = ""
                        agent.send(text)
                    }
                }
            ) {
                if (status == AgentStatus.Idle) {
                    Icon(Icons.Default.Send, contentDescription = "Send")
                } else {
                    Icon(Icons.Default.Stop, contentDescription = "Stop")
                }
            }
        }
    }
}

@Composable
private fun MessageBubble(turn: ChatTurn) {
    val isUser = turn.role == Role.user
    val bgColor = when (turn.role) {
        Role.user      -> MaterialTheme.colorScheme.primary
        Role.assistant -> MaterialTheme.colorScheme.surfaceVariant
        Role.tool      -> MaterialTheme.colorScheme.tertiaryContainer
        Role.system    -> MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.3f)
    }
    val fgColor = if (isUser) MaterialTheme.colorScheme.onPrimary
                  else MaterialTheme.colorScheme.onSurfaceVariant

    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            Modifier.widthIn(max = 280.dp)
        ) {
            if (turn.role == Role.tool) {
                Text(
                    "tool reply",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = bgColor,
            ) {
                Text(
                    text = turn.text.ifEmpty { "…" },
                    color = fgColor,
                    modifier = Modifier.padding(10.dp),
                )
            }
        }
    }
}

@Composable
private fun ToolPill(toolName: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Surface(
            shape = RoundedCornerShape(10.dp),
            color = Color(0xFFFFF4D5),
        ) {
            Text(
                text = "⚙ called $toolName",
                color = Color(0xFF806300),
                style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun StreamingBubble(text: String, activeTool: String?) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Column(Modifier.widthIn(max = 280.dp)) {
            if (activeTool != null) {
                Text(
                    "calling $activeTool…",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Text(
                    text = if (text.isEmpty()) "▍" else "$text▍",
                    modifier = Modifier.padding(10.dp),
                )
            }
        }
    }
}

@Composable
private fun LoadingStub() {
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator()
        Spacer(Modifier.height(12.dp))
        Text(
            "Loading model + booting Dazzle…",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ErrorBanner(message: String) {
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Couldn't start", style = MaterialTheme.typography.titleMedium)
        Text(
            message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
