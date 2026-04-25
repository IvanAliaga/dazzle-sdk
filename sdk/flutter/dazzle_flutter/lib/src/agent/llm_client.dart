// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Abstract LLM client — the protocol ChatAgent drives. Same 4-adapter
// design as Kotlin / Swift. Concrete adapters live under src/edge/.

import 'message.dart';
import 'tool.dart';

/// Every concrete LLM adapter (Llama.cpp, LiteRT, OpenAI-compat,
/// FoundationModels) implements this contract. Swap in one line —
/// ChatAgent, ToolContext, and all the surrounding plumbing stay
/// identical.
abstract class LLMClient {
  String get modelId;

  /// Blocking completion. Returns either a final `CompletionText` or
  /// `CompletionToolCalls` — caller invokes tools and re-calls with
  /// the augmented history.
  Future<Completion> complete({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  });

  /// Streaming version — emits `Delta` events until a single `DeltaEnd`.
  /// Cancelling the returned subscription aborts the native call.
  Stream<Delta> stream({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  });

  /// Release native resources (model weights, contexts). Must be safe
  /// to call multiple times.
  Future<void> close();
}

/// A scripted fake — mirrors `FakeLLMClient.kt` / `FakeLLMClient.swift`
/// one-to-one. Lets the sample test harness exercise the full agent
/// loop without a 1 GB model download.
class FakeLLMClient implements LLMClient {
  FakeLLMClient({
    this.modelId = 'fake:test',
    required List<Completion> script,
  }) : _script = List.of(script);

  @override
  final String modelId;

  final List<Completion> _script;
  int _cursor = 0;

  int get callCount => _cursor;

  @override
  Future<Completion> complete({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async {
    if (_cursor >= _script.length) {
      throw StateError('FakeLLMClient script exhausted');
    }
    return _script[_cursor++];
  }

  @override
  Stream<Delta> stream({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async* {
    if (_cursor >= _script.length) {
      throw StateError('FakeLLMClient script exhausted');
    }
    final next = _script[_cursor++];
    switch (next) {
      case CompletionText(:final message):
        // Chunk into 8-char pieces to match the native behavior.
        final text = message.content;
        for (var i = 0; i < text.length; i += 8) {
          final end = (i + 8).clamp(0, text.length);
          yield DeltaText(text.substring(i, end));
        }
      case CompletionToolCalls(:final message):
        for (final call in message.toolCalls) {
          yield DeltaToolCallStart(id: call.id, name: call.name);
          final args = call.arguments;
          for (var i = 0; i < args.length; i += 8) {
            final end = (i + 8).clamp(0, args.length);
            yield DeltaToolCallArgs(id: call.id, chunk: args.substring(i, end));
          }
        }
    }
    yield const DeltaEnd();
  }

  @override
  Future<void> close() async {}
}
