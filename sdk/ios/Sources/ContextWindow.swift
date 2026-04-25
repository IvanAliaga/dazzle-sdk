// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation

/// How the agent assembles the in-flight prompt from its stored history.
///
/// Different from `CompactionPolicy`: ContextWindow is about WHAT goes
/// into this LLM call; CompactionPolicy is about WHAT STAYS IN STORAGE.
public enum ContextWindow: @unchecked Sendable {
    /// Keep the most recent N turns verbatim.
    case lastN(Int)

    /// Keep the most recent `keepRecent` turns AND prepend the top-`k`
    /// turns retrieved semantically from `store` against the current
    /// user input.
    case vectorRecall(
        keepRecent: Int,
        k: Int,
        store: DazzleContextStore<ChatTurn>,
        embedder: @Sendable (String) -> [Float]
    )

    /// Pass the full history. Safe only when storage is known-bounded.
    case all

    /// Sensible default for a single-session chat agent.
    public static let `default`: ContextWindow = .lastN(20)
}
