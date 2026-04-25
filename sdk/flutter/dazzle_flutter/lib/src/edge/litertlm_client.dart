// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// LiteRtLmClient for Flutter — delegates to the native Kotlin / Swift
// `LiteRtLmClient` via a scoped method channel. LiteRT-LM isn't a plain
// C surface (Google's runtime is JVM-side on Android, wrapped in a
// Swift framework on iOS), so method-channel reuse is the clean play.
//
// Streaming: native emits `token` events over an EventChannel; we
// translate each into `Delta.text`.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../agent/llm_client.dart';
import '../agent/message.dart';
import '../agent/tool.dart';

class LiteRtLmClient implements LLMClient {
  LiteRtLmClient._(this._handle, this.modelId);

  @override final String modelId;
  final int _handle;

  static const MethodChannel _method =
      MethodChannel('dev.dazzle.flutter/litertlm');
  static const EventChannel _events =
      EventChannel('dev.dazzle.flutter/litertlm.tokens');

  static Future<LiteRtLmClient> create({
    required String modelPath,
    String? modelId,
    String systemPrompt = 'You are a helpful on-device AI assistant.',
    double temperature = 0.01,
    int maxTokens = 512,
  }) async {
    final args = {
      'modelPath': modelPath,
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'maxTokens': maxTokens,
    };
    final handle = await _method.invokeMethod<int>('create', args);
    if (handle == null) {
      throw StateError('LiteRtLmClient.create returned null handle');
    }
    return LiteRtLmClient._(handle,
        modelId ?? modelPath.split(Platform.pathSeparator).last);
  }

  @override
  Future<Completion> complete({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async {
    final buffer = StringBuffer();
    await for (final d in stream(messages: messages, tools: tools)) {
      if (d is DeltaText) buffer.write(d.chunk);
    }
    return CompletionText(
        Message(role: Role.assistant, content: buffer.toString()));
  }

  @override
  Stream<Delta> stream({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) {
    final streamId = ++_nextStreamId;
    final args = {
      'handle':   _handle,
      'streamId': streamId,
      'messages': messages
          .map((m) => {
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
              })
          .toList(),
      'tools': tools
          .map((t) => {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters.serialize(),
              })
          .toList(),
    };
    final controller = StreamController<Delta>();
    StreamSubscription? sub;
    sub = _events.receiveBroadcastStream(args).listen(
      (raw) {
        final m = Map<String, dynamic>.from(raw as Map);
        // Drop residual frames from older subscriptions —
        // Flutter's EventChannel buffer occasionally replays the
        // previous turn's `type:"end"` to a fresh listener,
        // closing this controller before any real chunk arrives.
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
    await _method.invokeMethod<void>('close', {'handle': _handle});
  }
}

