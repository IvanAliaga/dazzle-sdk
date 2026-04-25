// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// AnthropicClient (Dart shim) — talks to Anthropic's `/v1/messages`
// API via the native bridge. The actual HTTP + SSE parsing happens
// in Kotlin (`AnthropicClient.kt`) on Android and Swift
// (`AnthropicClient.swift`) on iOS — this file is a thin wrapper
// over the `dev.dazzle.flutter/anthropic` method + event channels.
//
// Why bridge instead of a pure-Dart `package:http` implementation?
// One reason: keep the wire format conversion (Dazzle Message[] →
// Anthropic content blocks, tool_result wrapping, SSE event parsing)
// in a single language per platform. If Anthropic changes the API
// we edit two files (Kotlin + Swift), not four.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../agent/llm_client.dart';
import '../agent/message.dart';
import '../agent/tool.dart';

class AnthropicClient implements LLMClient {
  AnthropicClient._({
    required this.modelId,
    required int handle,
  }) : _handle = handle;

  static const MethodChannel _method =
      MethodChannel('dev.dazzle.flutter/anthropic');
  static const EventChannel _events =
      EventChannel('dev.dazzle.flutter/anthropic.tokens');

  @override
  final String modelId;
  final int _handle;
  bool _closed = false;

  /// Spawn a fresh Anthropic-backed client. The native side keeps the
  /// handle alive until [close] runs — until then `complete` and
  /// `stream` re-use the same (model, apiKey, baseURL, version, …)
  /// configuration with no per-call setup.
  static Future<AnthropicClient> create({
    required String model,
    required String apiKey,
    String baseURL = 'https://api.anthropic.com/v1',
    String anthropicVersion = '2023-06-01',
    int maxTokens = 1024,
    double? temperature,
    double? topP,
    Map<String, String> extraHeaders = const {},
  }) async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      throw UnsupportedError(
          'AnthropicClient requires the dazzle_flutter plugin '
          '(Android / iOS / macOS).');
    }
    final handle = await _method.invokeMethod<int>('create', {
      'model': model,
      'apiKey': apiKey,
      'baseURL': baseURL,
      'anthropicVersion': anthropicVersion,
      'maxTokens': maxTokens,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'topP': topP,
      if (extraHeaders.isNotEmpty) 'extraHeaders': extraHeaders,
    });
    if (handle == null) {
      throw StateError('AnthropicClient.create returned no handle');
    }
    return AnthropicClient._(modelId: model, handle: handle);
  }

  @override
  Future<Completion> complete({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async {
    _ensureOpen();
    final raw = await _method.invokeMethod<Map<dynamic, dynamic>>('complete', {
      'handle': _handle,
      'messages': messages.map(_encodeMessage).toList(),
      'tools':    tools.map(_encodeTool).toList(),
    });
    if (raw == null) {
      throw StateError('AnthropicClient.complete returned null');
    }
    final m = Map<String, dynamic>.from(raw);
    final content = (m['content'] as String?) ?? '';
    if (m['type'] == 'toolCalls') {
      final calls = (m['toolCalls'] as List? ?? const [])
          .map((c) {
            final cm = Map<String, dynamic>.from(c as Map);
            return ToolCall(
              id:        cm['id']        as String? ?? '',
              name:      cm['name']      as String? ?? '',
              arguments: cm['arguments'] as String? ?? '{}',
            );
          })
          .toList();
      return CompletionToolCalls(Message(
        role: Role.assistant,
        content: content,
        toolCalls: calls,
      ));
    }
    return CompletionText(Message(role: Role.assistant, content: content));
  }

  @override
  Stream<Delta> stream({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) {
    _ensureOpen();
    // Each `stream()` call gets a unique cookie. The bridge tags
    // every frame it emits with this cookie; the shim filters out
    // anything that doesn't match. Without this, the platform-side
    // `EventChannel` buffer occasionally replays the previous turn's
    // `type:"end"` frame to the next subscription, which would close
    // turn N+1's controller before any real chunk arrives.
    final streamId = ++_nextStreamId;
    final args = {
      'handle':   _handle,
      'streamId': streamId,
      'messages': messages.map(_encodeMessage).toList(),
      'tools':    tools.map(_encodeTool).toList(),
    };

    final controller = StreamController<Delta>();
    StreamSubscription? sub;
    sub = _events.receiveBroadcastStream(args).listen(
      (raw) {
        final m = Map<String, dynamic>.from(raw as Map);
        // Drop residuals from older subscriptions. Flutter
        // EventChannel sometimes replays the previous turn's
        // `type:"end"` to a fresh listener; this filter pins each
        // controller to its own stream cookie.
        final frameStreamId = m['streamId'];
        if (frameStreamId is int && frameStreamId != streamId) return;
        switch (m['type']) {
          case 'text':
            controller.add(DeltaText(m['chunk'] as String? ?? ''));
          case 'toolCallStart':
            controller.add(DeltaToolCallStart(
                id: m['id'] as String, name: m['name'] as String));
          case 'toolCallArgs':
            controller.add(DeltaToolCallArgs(
                id: m['id'] as String, chunk: m['chunk'] as String));
          case 'end':
            controller.add(const DeltaEnd());
            controller.close();
            sub?.cancel();
        }
      },
      onError: (e, st) {
        controller.addError(e, st);
        controller.close();
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );
    return controller.stream;
  }

  static int _nextStreamId = 0;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _method.invokeMethod<void>('close', {'handle': _handle});
  }

  // ── helpers ───────────────────────────────────────────────────────

  void _ensureOpen() {
    if (_closed) {
      throw StateError('AnthropicClient is closed');
    }
  }

  Map<String, dynamic> _encodeMessage(Message m) {
    return {
      'role': m.role.wire,
      'content': m.content,
      if (m.toolCallId != null) 'toolCallId': m.toolCallId,
      if (m.toolCalls.isNotEmpty)
        'toolCalls': m.toolCalls
            .map((c) => {
                  'id': c.id,
                  'name': c.name,
                  'arguments': c.arguments,
                })
            .toList(),
    };
  }

  Map<String, dynamic> _encodeTool(ToolDeclaration t) {
    return {
      'name':        t.name,
      'description': t.description,
      'parameters':  t.parameters.serialize(),
    };
  }
}
