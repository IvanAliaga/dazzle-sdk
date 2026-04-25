// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.demo

import dev.dazzle.sdk.Completion
import dev.dazzle.sdk.Delta
import dev.dazzle.sdk.LLMClient
import dev.dazzle.sdk.Message
import dev.dazzle.sdk.Role
import dev.dazzle.sdk.ToolDeclaration
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Demo-only [LLMClient] that echoes the user's last message back with
 * a short prefix. Streams character-by-character with a small delay so
 * the UI shows a believable "typing" animation.
 *
 * Swap this for `LiteRtLmClient` (edge package) or any cloud API
 * adapter to drive the same ChatActivity with a real model — the only
 * thing the UI layer knows is the [dev.dazzle.sdk.Agent] interface.
 */
class EchoLLMClient(
    private val chunkDelayMs: Long = 25,
) : LLMClient {

    override val modelId: String = "demo:echo"

    override suspend fun complete(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Completion {
        val reply = generateReply(messages)
        return Completion.Text(Message(role = Role.assistant, content = reply))
    }

    override fun stream(
        messages: List<Message>,
        tools: List<ToolDeclaration>,
    ): Flow<Delta> = flow {
        val reply = generateReply(messages)
        for (ch in reply) {
            emit(Delta.Text(ch.toString()))
            if (chunkDelayMs > 0) delay(chunkDelayMs)
        }
        emit(Delta.End)
    }

    override fun close() {}

    private fun generateReply(messages: List<Message>): String {
        val lastUser = messages.lastOrNull { it.role == Role.user }?.content.orEmpty()
        val turnCount = messages.count { it.role == Role.user }
        if (lastUser.isEmpty()) {
            return "Hi! I'm the Dazzle demo echo. Try asking me something."
        }
        val suffix = if (turnCount == 1) "" else "s"
        return "You said: \"$lastUser\". This conversation has $turnCount turn$suffix."
    }
}
