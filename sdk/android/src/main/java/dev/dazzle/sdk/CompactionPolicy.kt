// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk

import kotlin.time.Duration

/**
 * How the agent keeps its persistent memory bounded.
 *
 * Without compaction a 500-turns-per-month conversation balloons to
 * MBs of hash entries + 1.8M floats in the vector index after a year —
 * unsustainable on-device. Compaction runs on a trigger (per-turn or
 * on-demand via [Agent.compact]) and shrinks the [ContextStore] in
 * place.
 *
 * **Different from [ContextWindow]**: Window picks WHAT goes into a
 * single LLM call; Compaction picks WHAT STAYS IN STORAGE. They compose.
 */
sealed interface CompactionPolicy {

    /** Never compact. Memory grows unbounded — only safe for short-lived
     *  sessions where the process itself dies before storage does. */
    data object None : CompactionPolicy

    /** Delete every turn older than [retention]. Hard cutoff. Cheap,
     *  predictable, loses old context permanently.
     *
     *  Good for event-driven chats where old context isn't useful
     *  (customer support, transactional flows). */
    data class TimeRetention(val retention: Duration) : CompactionPolicy

    /** Keep only the latest [maxTurns]. Older turns are deleted outright.
     *
     *  Simple bound on memory size. Prefer over [TimeRetention] when the
     *  user's usage pattern is bursty (many turns in a short window). */
    data class MaxTurns(val maxTurns: Int) : CompactionPolicy {
        init { require(maxTurns > 0) { "maxTurns must be positive" } }
    }

    /** Every [everyNTurns] turns, summarize the oldest block (all turns
     *  older than the last [keepRecent]) into a single assistant turn,
     *  then delete the originals. Preserves semantic context at a
     *  fraction of the token cost.
     *
     *  [summarizer] is provided by the caller — usually a small helper
     *  that feeds the old block back to the same LLM with a "Summarize
     *  this conversation in ≤200 tokens" system prompt. */
    data class RollingSummary(
        val everyNTurns: Int = 50,
        val keepRecent: Int = 20,
        val summarizer: suspend (List<ChatTurn>) -> String,
    ) : CompactionPolicy {
        init {
            require(everyNTurns > 0) { "everyNTurns must be positive" }
            require(keepRecent >= 0) { "keepRecent must be non-negative" }
            require(everyNTurns > keepRecent) {
                "everyNTurns ($everyNTurns) must be > keepRecent ($keepRecent)"
            }
        }
    }

    /** Caller-provided compaction — full control. Invoked whenever the
     *  Agent decides to compact (per-turn or on-demand). */
    data class Custom(val fn: suspend (ContextStore<ChatTurn>) -> Unit) : CompactionPolicy

    companion object {
        /** Default — keep the last 200 turns. Safe for typical chat
         *  sessions and does not require an LLM summarizer. */
        val default: CompactionPolicy = MaxTurns(maxTurns = 200)
    }
}
