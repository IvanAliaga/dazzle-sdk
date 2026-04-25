// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

/**
 * How the agent assembles the in-flight prompt from its stored history.
 *
 * The LLM has a hard token limit per call (Gemma 3N E2B: 8K, Llama 3.2
 * 3B: 128K). Every time we call `send()`, the agent walks the memory and
 * picks a subset of past turns to include. This policy determines which.
 *
 * **Different from [CompactionPolicy]**: ContextWindow is about "what
 * goes in THIS call"; CompactionPolicy is about "what stays in STORAGE
 * long-term". The two compose — a store pruned by compaction can still
 * overflow a single call if the remaining history is too verbose.
 */
sealed interface ContextWindow {

    /** Keep the most recent [n] turns, verbatim.
     *
     *  Cheap, predictable, and suffices for most short-lived chat agents.
     *  For a Gemma 3N E2B with 8K tokens and ~100 tokens per turn, `n = 20`
     *  leaves plenty of headroom for the system prompt + user input. */
    data class LastN(val n: Int) : ContextWindow {
        init { require(n > 0) { "LastN.n must be positive, got $n" } }
    }

    /** Keep the most recent [keepRecent] turns AND prepend the top-[k]
     *  turns retrieved semantically from [store] against the current
     *  user input.
     *
     *  Useful for long-lived conversations where old turns are still
     *  relevant (the user references something from weeks ago). Requires
     *  [store] to have a `semanticSearch` hook configured. */
    data class VectorRecall(
        val keepRecent: Int = 10,
        val k: Int = 5,
        val store: ContextStore<ChatTurn>,
        val embedder: (String) -> FloatArray,
    ) : ContextWindow {
        init {
            require(keepRecent > 0) { "keepRecent must be positive" }
            require(k > 0) { "k must be positive" }
        }
    }

    /** Pass the full stored history. Only safe when the dev knows the
     *  memory never grows beyond the model's context (a [CompactionPolicy]
     *  of [CompactionPolicy.MaxTurns] or [CompactionPolicy.TimeRetention]
     *  is the usual companion). */
    data object All : ContextWindow

    companion object {
        /** Sensible default for a single-session chat agent. */
        val default: ContextWindow = LastN(n = 20)
    }
}
