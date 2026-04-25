// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Observable ChatAgent — mirrors `ChatAgentImpl.swift` / `.kt` so
// Flutter UI code can listen to three `ValueNotifier`s (messages /
// streaming / status) exactly like Compose/SwiftUI does with
// StateFlow / @Observable.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../server.dart';
import '../vector/vector_index.dart';
import 'context_store.dart';
import 'context_window.dart';
import 'llm_client.dart';
import 'message.dart';
import 'tool.dart';

/// Embed a string into a fixed-dim vector. Same shape Kotlin + Swift
/// SDKs expose; consumers plug their own embedder (BGE-small via
/// llama.cpp --embedding, OpenAI's `/embeddings` API, a hash-bucket
/// toy for demos, …).
typedef Embedder = Future<List<double>> Function(String text);

/// Observable chat agent. UI binds to [messages], [streaming], and
/// [status] via `AnimatedBuilder` / `ValueListenableBuilder`.
class ChatAgent {
  ChatAgent({
    required this.threadId,
    required this.llm,
    this.tools = const [],
    this.systemPrompt = 'You are a helpful assistant.',
    this.systemPromptVars,
    this.contextWindow = const LastNWindow(40),
    this.compaction = const CompactionMaxTurns(200),
    this.maxToolIterations = 8,
    this.embedder,
    this.embeddingDim,
  }) : _memory = _chatTurnStore(threadId) {
    // Restore prior history from the persistent store on construction.
    final restored = <ChatTurn>[
      for (final (_, turn) in _memory.iterate()) turn,
    ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    messages.value = restored;

    // If VectorRecallWindow is configured and we have an embedder,
    // lazily build (or open) the companion vector index so turns can
    // be recalled semantically. The index key is derived from the
    // thread id — each conversation gets its own.
    if (contextWindow is VectorRecallWindow &&
        embedder != null &&
        embeddingDim != null && embeddingDim! > 0) {
      _vectorIndex = DazzleServer.shared.vectorIndex(
        name:        'agent:$threadId:idx',
        hashPrefix:  'agent:$threadId:memory',
        vectorField: 'emb',
        dim:         embeddingDim!,
        algorithm:   VectorAlgorithm.hnswSq8,
        metric:      VectorMetric.cosine,
      );
    }
  }

  final String threadId;
  final LLMClient llm;
  final List<Tool> tools;
  final String systemPrompt;
  final Map<String, String> Function()? systemPromptVars;
  final ContextWindow contextWindow;
  final CompactionPolicy compaction;
  final int maxToolIterations;

  /// Optional — only required when [contextWindow] is a
  /// [VectorRecallWindow]. Called once per persisted turn (to index
  /// it) and once per send (to build the retrieval query).
  final Embedder? embedder;
  final int? embeddingDim;

  final ContextStore<ChatTurn> _memory;
  VectorIndex? _vectorIndex;

  final ValueNotifier<List<ChatTurn>>          messages  = ValueNotifier([]);
  final ValueNotifier<StreamingMessage?>       streaming = ValueNotifier(null);
  final ValueNotifier<AgentStatus>             status    = ValueNotifier(AgentStatus.idle);

  StreamSubscription<Delta>? _currentStream;

  /// Kick off a user turn. Non-blocking — the UI should watch
  /// [status] and the message list notifiers to render progress.
  Future<void> send(String userInput) async {
    if (status.value != AgentStatus.idle) return;
    status.value = AgentStatus.thinking;
    try {
      await _runTurn(userInput);
    } catch (_) {
      status.value = AgentStatus.error;
      rethrow;
    } finally {
      streaming.value = null;
      if (status.value != AgentStatus.error) status.value = AgentStatus.idle;
    }
  }

  /// Cancel the in-flight turn, if any.
  void cancel() {
    _currentStream?.cancel();
    streaming.value = null;
    status.value = AgentStatus.idle;
  }

  Future<void> close() async {
    _currentStream?.cancel();
    messages.dispose();
    streaming.dispose();
    status.dispose();
    await llm.close();
  }

  // MARK: – Turn loop

  Future<void> _runTurn(String userInput) async {
    final userTurn = ChatTurn(
      id: _newId(), role: Role.user, text: userInput,
    );
    _memory.put(userTurn.id, userTurn);
    await _indexTurn(userTurn);
    messages.value = [...messages.value, userTurn];

    var iteration = 0;
    while (iteration < maxToolIterations) {
      iteration++;
      final history = await _assembleHistory(userInput);
      final prompt = <Message>[
        Message(role: Role.system, content: _renderSystemPrompt()),
        ...history.map((t) => t.toMessage()),
      ];
      final toolDecls = tools.map((t) => t.toDeclaration()).toList();

      status.value = AgentStatus.streaming;
      streaming.value = const StreamingMessage();

      final collected = await _collectStream(prompt, toolDecls);

      if (collected.toolCalls.isNotEmpty) {
        final assistantTurn = ChatTurn(
          id: _newId(), role: Role.assistant, text: collected.text,
          toolCalls: collected.toolCalls,
        );
        _memory.put(assistantTurn.id, assistantTurn);
        await _indexTurn(assistantTurn);
        messages.value = [...messages.value, assistantTurn];

        status.value = AgentStatus.toolCalling;
        for (final call in collected.toolCalls) {
          final response = await _runToolCall(call);
          final toolTurn = ChatTurn(
            id: _newId(), role: Role.tool,
            text: response, toolCallId: call.id,
          );
          _memory.put(toolTurn.id, toolTurn);
          await _indexTurn(toolTurn);
          messages.value = [...messages.value, toolTurn];
        }
        status.value = AgentStatus.thinking;
      } else {
        final finalTurn = ChatTurn(
          id: _newId(), role: Role.assistant, text: collected.text,
        );
        _memory.put(finalTurn.id, finalTurn);
        await _indexTurn(finalTurn);
        messages.value = [...messages.value, finalTurn];
        break;
      }
    }

    await _runCompaction(force: false);
  }

  Future<_StreamedTurn> _collectStream(
      List<Message> prompt, List<ToolDeclaration> toolDecls) async {
    var text = '';
    final builders = <String, ({String name, String args})>{};
    final callOrder = <String>[];

    final completer = Completer<void>();
    _currentStream = llm.stream(messages: prompt, tools: toolDecls).listen(
      (delta) {
        switch (delta) {
          case DeltaText(:final chunk):
            text += chunk;
            streaming.value = StreamingMessage(
                text: text, activeTool: streaming.value?.activeTool);
          case DeltaToolCallStart(:final id, :final name):
            builders[id] = (name: name, args: '');
            callOrder.add(id);
            streaming.value = StreamingMessage(text: text, activeTool: name);
          case DeltaToolCallArgs(:final id, :final chunk):
            final prev = builders[id];
            if (prev != null) {
              builders[id] = (name: prev.name, args: prev.args + chunk);
            }
          case DeltaEnd():
            break;
        }
      },
      onError: completer.completeError,
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    try {
      await completer.future;
    } finally {
      _currentStream = null;
    }

    final calls = [
      for (final id in callOrder)
        if (builders[id] case (:final name, :final args))
          ToolCall(id: id, name: name, arguments: args),
    ];
    return _StreamedTurn(text, calls);
  }

  Future<String> _runToolCall(ToolCall call) async {
    final tool = tools.firstWhere((t) => t.name == call.name,
        orElse: () => _UnknownToolSentinel());
    if (tool is _UnknownToolSentinel) {
      return _errorPayload('UnknownTool', 'Tool \'${call.name}\' not registered');
    }
    try {
      final ctx = ToolContext();
      return await tool.invokeRaw(call.arguments, ctx);
    } catch (e) {
      return _errorPayload(e.runtimeType.toString(), e.toString());
    }
  }

  Future<List<ChatTurn>> _assembleHistory(String userInput) async {
    final all = messages.value;
    return switch (contextWindow) {
      LastNWindow(:final n) =>
          all.length <= n ? all : all.sublist(all.length - n),
      AllHistoryWindow() => all,
      VectorRecallWindow(:final keepRecent, :final k) =>
          await _vectorRecall(userInput, keepRecent, k),
    };
  }

  /// Hybrid retrieval: keep the most recent [keepRecent] turns (so the
  /// local coherence of the conversation isn't lost) plus the top-[k]
  /// older turns most similar to [userInput] in embedding space.
  ///
  /// If we don't have an embedder / vector index wired, degrades to a
  /// plain LastN window — the contract never silently drops the
  /// whole conversation.
  Future<List<ChatTurn>> _vectorRecall(
      String userInput, int keepRecent, int k) async {
    final all = messages.value;
    final recent = all.length <= keepRecent
        ? all
        : all.sublist(all.length - keepRecent);
    if (_vectorIndex == null || embedder == null || k <= 0) return recent;
    if (all.length <= keepRecent) return recent;

    final recentIds = {for (final t in recent) t.id};
    try {
      final vec = await embedder!(userInput);
      final hits = _vectorIndex!.searchDirect(vec, k: k + keepRecent);
      final byId = {for (final t in all) t.id: t};
      final recalled = <ChatTurn>[];
      for (final h in hits) {
        // The vector index stores ids as `agent:<thread>:memory:<turnId>`
        // (hashPrefix collision with ContextStore). Strip back to the
        // turn id we indexed by.
        final raw = h.id;
        final idx = raw.lastIndexOf(':');
        final turnId = idx >= 0 ? raw.substring(idx + 1) : raw;
        if (recentIds.contains(turnId)) continue;
        final turn = byId[turnId];
        if (turn != null) {
          recalled.add(turn);
          if (recalled.length >= k) break;
        }
      }
      recalled.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return [...recalled, ...recent];
    } catch (_) {
      return recent;
    }
  }

  Future<void> _indexTurn(ChatTurn turn) async {
    final idx = _vectorIndex;
    final embed = embedder;
    if (idx == null || embed == null || turn.text.isEmpty) return;
    try {
      final vec = await embed(turn.text);
      idx.addDirect('agent:$threadId:memory:${turn.id}', vec);
    } catch (_) {
      // Indexing is best-effort — a bad embedder call shouldn't break
      // the chat loop.
    }
  }

  String _renderSystemPrompt() {
    var out = systemPrompt;
    final vars = systemPromptVars?.call() ?? {};
    vars.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  Future<void> _runCompaction({required bool force}) async {
    switch (compaction) {
      case CompactionNone():
        return;
      case CompactionMaxTurns(:final maxTurns):
        if (!force && messages.value.length <= maxTurns) return;
        final drop = messages.value.length - maxTurns;
        if (drop > 0) {
          final toDrop = messages.value.sublist(0, drop);
          for (final t in toDrop) {
            _memory.delete(t.id);
          }
          messages.value = messages.value.sublist(drop);
        }
    }
  }

  static String _errorPayload(String code, String message) =>
      jsonEncode({'error': code, 'message': message});

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  static int _counter = 0;
}

class _StreamedTurn {
  final String text;
  final List<ToolCall> toolCalls;
  _StreamedTurn(this.text, this.toolCalls);
}

class _UnknownToolSentinel extends Tool<Object, Object> {
  @override String get name => '__unknown__';
  @override String get description => '';
  @override JsonSchema get argsSchema => const JsonSchemaObject();
  @override Future<Object> invoke(Object args, ToolContext ctx) async =>
      <String, Object?>{};
  @override Object argsFromJson(String raw) => const Object();
  @override String returnToJson(Object value) => '{}';
}

// Factory for the ChatTurn-specific ContextStore — keeps encode/decode
// colocated with the agent so users don't have to hand-write it.
ContextStore<ChatTurn> _chatTurnStore(String threadId) {
  return ContextStore<ChatTurn>(
    name: 'agent:$threadId:memory',
    encode: (t) {
      final out = {
        'id': t.id,
        'role': t.role.wire,
        'text': t.text,
        'ts': '${t.timestamp}',
      };
      if (t.toolCallId != null) out['toolCallId'] = t.toolCallId!;
      if (t.toolCalls.isNotEmpty) {
        out['toolCalls'] = _encodeToolCalls(t.toolCalls);
      }
      return out;
    },
    decode: (f) {
      final roleName = f['role'];
      final text = f['text'];
      final ts = int.tryParse(f['ts'] ?? '');
      final id = f['__id'] ?? f['id'];
      if (roleName == null || text == null || ts == null || id == null) {
        return null;
      }
      return ChatTurn(
        id: id,
        role: RoleSerde.fromWire(roleName),
        text: text,
        toolCallId: f['toolCallId'],
        toolCalls: f['toolCalls'] != null
            ? _decodeToolCalls(f['toolCalls']!)
            : const [],
        timestamp: ts,
      );
    },
  );
}

String _encodeToolCalls(List<ToolCall> calls) {
  final sb = StringBuffer('[');
  for (var i = 0; i < calls.length; i++) {
    if (i > 0) sb.write('|');
    final c = calls[i];
    sb..write(c.id)..write('~')..write(c.name)..write('~')
      ..write(c.arguments.replaceAll('|', r'\|'));
  }
  sb.write(']');
  return sb.toString();
}

List<ToolCall> _decodeToolCalls(String raw) {
  if (raw.length < 2 || raw[0] != '[' || raw[raw.length - 1] != ']') {
    return const [];
  }
  final body = raw.substring(1, raw.length - 1);
  if (body.isEmpty) return const [];
  return body.split('|').map((chunk) {
    final parts = chunk.split('~');
    if (parts.length < 3) return null;
    return ToolCall(
      id: parts[0],
      name: parts[1],
      arguments: parts.sublist(2).join('~').replaceAll(r'\|', '|'),
    );
  }).whereType<ToolCall>().toList();
}

/// Factory method on DazzleServer — `server.chatAgent(threadId: …, llm: …)`
extension DazzleServerChatAgent on DazzleServer {
  ChatAgent chatAgent({
    required String threadId,
    required LLMClient llm,
    List<Tool> tools = const [],
    String systemPrompt = 'You are a helpful assistant.',
    ContextWindow contextWindow = const LastNWindow(40),
    CompactionPolicy compaction = const CompactionMaxTurns(200),
    int maxToolIterations = 8,
    Embedder? embedder,
    int? embeddingDim,
  }) =>
      ChatAgent(
        threadId: threadId,
        llm: llm,
        tools: tools,
        systemPrompt: systemPrompt,
        contextWindow: contextWindow,
        compaction: compaction,
        maxToolIterations: maxToolIterations,
        embedder: embedder,
        embeddingDim: embeddingDim,
      );
}
