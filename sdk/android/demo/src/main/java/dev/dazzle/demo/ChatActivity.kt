// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dazzle.sdk.Agent
import dev.dazzle.sdk.AgentStatus
import dev.dazzle.sdk.ChatTurn
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.edge.DazzleEdge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Compose chat screen wired to a [DazzleEdge.chatAgent] running
 * against [EchoLLMClient]. End-to-end this exercises:
 *
 * 1. Layer 1 — embedded Valkey booted by DazzleEdge
 * 2. Layer 2 — ContextStore<ChatTurn> persisting the history
 * 3. Layer 3 — DazzleEdge.chatAgent as the one-liner entry point
 * 4. StateFlow-backed observable state driving Compose re-composition
 *
 * Swap [EchoLLMClient] for `LiteRtLmClient` (in the edge package) or
 * any cloud adapter to drive the same screen with a real model — the
 * UI talks only to the `Agent` interface.
 */
class ChatActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ChatScreen()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatScreen() {
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current
    var agent by remember { mutableStateOf<Agent?>(null) }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    // Lazy agent construction — DazzleEdge.chatAgent boots the Valkey
    // server on first call so we want it off the main thread.
    LaunchedEffect(Unit) {
        if (agent != null) return@LaunchedEffect
        try {
            val built = withContext(Dispatchers.IO) {
                DazzleEdge.chatAgent(context, llm = EchoLLMClient(), threadId = "demo-default") {
                    systemPrompt = "You are the Dazzle on-device chat demo."
                }
            }
            agent = built
        } catch (t: Throwable) {
            errorMsg = t.message ?: t.javaClass.simpleName
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Dazzle Chat") },
                actions = {
                    agent?.let { StatusBadge(it) }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentAlignment = Alignment.Center,
        ) {
            val currentAgent = agent
            when {
                currentAgent != null -> ChatBody(currentAgent, scope)
                errorMsg != null -> ErrorView(errorMsg!!)
                else -> LoadingView()
            }
        }
    }
}

@Composable
private fun ChatBody(
    agent: Agent,
    scope: kotlinx.coroutines.CoroutineScope,
) {
    val messages by agent.messages.collectAsStateWithLifecycle()
    val streaming by agent.streaming.collectAsStateWithLifecycle()
    val status by agent.status.collectAsStateWithLifecycle()
    var input by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // Auto-scroll to the bottom when messages arrive or the streaming
    // bubble updates.
    LaunchedEffect(messages.size, streaming?.text) {
        val targetIdx = when {
            streaming != null -> messages.size  // streaming bubble sits past committed messages
            else              -> (messages.size - 1).coerceAtLeast(0)
        }
        if (targetIdx >= 0) listState.animateScrollToItem(targetIdx)
    }

    Column(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            state = listState,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(messages, key = { it.id }) { turn ->
                MessageRow(turn)
            }
            streaming?.let {
                item(key = "streaming") {
                    StreamingRow(text = it.text, activeTool = it.activeTool)
                }
            }
        }

        HorizontalDivider()

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp)
                .imePadding(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = input,
                onValueChange = { input = it },
                modifier = Modifier.weight(1f),
                enabled = status == AgentStatus.Idle,
                singleLine = true,
                placeholder = { Text("Message") },
                keyboardActions = KeyboardActions(onSend = {
                    submit(agent, input, onCleared = { input = "" }, scope)
                }),
            )
            IconButton(
                enabled = status == AgentStatus.Idle && input.trim().isNotEmpty(),
                onClick = { submit(agent, input, onCleared = { input = "" }, scope) },
            ) {
                if (status == AgentStatus.Idle) {
                    Text("▶", style = MaterialTheme.typography.titleLarge)
                } else {
                    CircularProgressIndicator(modifier = Modifier.width(20.dp))
                }
            }
        }
    }
}

private fun submit(
    agent: Agent,
    input: String,
    onCleared: () -> Unit,
    scope: kotlinx.coroutines.CoroutineScope,
) {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return
    onCleared()
    scope.launch { agent.send(trimmed) }
}

@Composable
private fun StatusBadge(agent: Agent) {
    val status by agent.status.collectAsStateWithLifecycle()
    val label = when (status) {
        AgentStatus.Idle -> "idle"
        AgentStatus.Thinking -> "thinking…"
        AgentStatus.Streaming -> "streaming"
        AgentStatus.ToolCalling -> "tool"
        AgentStatus.Error -> "error"
    }
    Row(
        modifier = Modifier.padding(end = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.labelSmall)
        if (status != AgentStatus.Idle && status != AgentStatus.Error) {
            Spacer(Modifier.width(6.dp))
            CircularProgressIndicator(modifier = Modifier.width(14.dp))
        }
    }
}

// ── Bubbles ─────────────────────────────────────────────────────────────

@Composable
private fun MessageRow(turn: ChatTurn) {
    if (turn.role == Role.system) return  // hide system prompts from the bubble list
    val isUser = turn.role == Role.user
    val bg =
        if (isUser) MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
        else MaterialTheme.colorScheme.surfaceVariant
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            color = bg,
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Text(
                text = turn.text.ifEmpty { "(no content)" },
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun StreamingRow(text: String, activeTool: String?) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Column(modifier = Modifier.widthIn(max = 320.dp)) {
            if (!activeTool.isNullOrEmpty()) {
                Text(
                    activeTool,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
            Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                shape = RoundedCornerShape(14.dp),
            ) {
                Text(
                    text = text.ifEmpty { "…" },
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

// ── Non-chat-ready states ───────────────────────────────────────────────

@Composable
private fun LoadingView() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CircularProgressIndicator()
        Text("Starting Dazzle chat…", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun ErrorView(msg: String) {
    Column(
        modifier = Modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Couldn't start chat", style = MaterialTheme.typography.titleMedium)
        Text(msg, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    }
}
