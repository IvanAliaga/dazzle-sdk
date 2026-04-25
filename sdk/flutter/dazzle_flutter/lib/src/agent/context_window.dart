// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// ContextWindow + CompactionPolicy — same shape as Kotlin / Swift.
// VectorRecallWindow ships a placeholder; it's wired in F3 once the
// LLM adapters + embedding path are in place.

/// Controls which subset of message history is passed to the LLM
/// each turn.
sealed class ContextWindow {
  const ContextWindow();
}

class LastNWindow extends ContextWindow {
  final int n;
  const LastNWindow(this.n);
}

class AllHistoryWindow extends ContextWindow {
  const AllHistoryWindow();
}

/// Hybrid: keep the most recent K turns AS-IS plus pull the top-k
/// semantically closest older turns via the provided vector store.
/// The embedder converts the current user input to a query vector.
class VectorRecallWindow extends ContextWindow {
  final int keepRecent;
  final int k;
  const VectorRecallWindow({required this.keepRecent, this.k = 5});
}

/// Controls when / how old turns are discarded or summarised to keep
/// the Dazzle store from growing unboundedly.
sealed class CompactionPolicy {
  const CompactionPolicy();
}

class CompactionNone extends CompactionPolicy {
  const CompactionNone();
}

class CompactionMaxTurns extends CompactionPolicy {
  final int maxTurns;
  const CompactionMaxTurns(this.maxTurns);
}
