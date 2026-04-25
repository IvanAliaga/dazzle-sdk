// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// FoundationModelsClient — Apple Intelligence 3B on iOS 26+ / macOS
// 26+. Platform-only; Android callers should get a clear "not
// supported" error up front so they can fall back to LlamaCppClient.
//
// Method channel only — Apple's SystemLanguageModel API is a Swift
// type with no C ABI, so there's nothing for dart:ffi to bind to.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../agent/llm_client.dart';
import '../agent/message.dart';
import '../agent/tool.dart';

class FoundationModelsClient implements LLMClient {
  FoundationModelsClient({
    this.systemPrompt = 'You are a helpful on-device AI assistant.',
    this.temperature,
    this.maxTokens,
  });

  static const MethodChannel _method =
      MethodChannel('dev.dazzle.flutter/foundation');
  static const EventChannel _events =
      EventChannel('dev.dazzle.flutter/foundation.tokens');

  @override final String modelId = 'apple:foundation-models';
  final String systemPrompt;
  final double? temperature;
  final int? maxTokens;

  /// True when Apple reports the default Foundation Models pipeline
  /// ready on this device. On non-Apple platforms always returns
  /// false.
  static Future<bool> get isAvailable async {
    if (!(Platform.isIOS || Platform.isMacOS)) return false;
    final v = await _method.invokeMethod<bool>('isAvailable');
    return v ?? false;
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
    if (!(Platform.isIOS || Platform.isMacOS)) {
      return Stream.error(UnsupportedError(
          'FoundationModelsClient is iOS/macOS 26+ only; '
          'use LlamaCppClient or OpenAICompatibleClient on other platforms'));
    }

    final streamId = ++_nextStreamId;
    final args = {
      'systemPrompt': systemPrompt,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'maxTokens': maxTokens,
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
        // Drop residuals from older subscriptions — Flutter's
        // EventChannel buffer occasionally replays the previous
        // turn's `type:"end"` to a fresh listener.
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
  Future<void> close() async {}
}
