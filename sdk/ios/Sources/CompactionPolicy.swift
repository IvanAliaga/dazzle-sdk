// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// How the agent keeps its persistent memory bounded.
///
/// Without compaction a long-lived conversation balloons storage —
/// unsustainable on-device. Compaction runs on a trigger (per-turn or
/// on-demand via `Agent.compact`) and shrinks the store in place.
public enum CompactionPolicy: @unchecked Sendable {
    /// Never compact. Memory grows unbounded.
    case none

    /// Delete every turn older than `retention`.
    case timeRetention(Duration)

    /// Keep only the latest N turns. Older turns are deleted outright.
    case maxTurns(Int)

    /// Every `everyNTurns`, summarize the oldest block (all turns older
    /// than the last `keepRecent`) into a single assistant turn via the
    /// caller-provided `summarizer`, then delete the originals.
    case rollingSummary(
        everyNTurns: Int,
        keepRecent: Int,
        summarizer: @Sendable ([ChatTurn]) async -> String
    )

    /// Caller-provided compaction — full control.
    case custom(@Sendable (DazzleContextStore<ChatTurn>) async -> Void)

    /// Default — keep the last 200 turns.
    public static let `default`: CompactionPolicy = .maxTurns(200)
}
