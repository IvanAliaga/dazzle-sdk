// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Message + ChatTurn + ToolCall + Delta types. Same shape as
// `Message.kt` / `Message.swift` so JSON payloads round-trip cleanly
// between native and Flutter consumers of the same Dazzle store.

enum Role { system, user, assistant, tool }

extension RoleSerde on Role {
  String get wire => name; // lowercase matches Kotlin/Swift enum.
  static Role fromWire(String s) =>
      Role.values.firstWhere((r) => r.name == s, orElse: () => Role.user);
}

class ToolCall {
  final String id;
  final String name;
  final String arguments;   // raw JSON
  const ToolCall({required this.id, required this.name, required this.arguments});
}

/// Input to `LLMClient.complete` / `stream`. Mirrors the native
/// `Message` exactly so a Dazzle persistence file written by a Kotlin
/// app reads fine from Flutter.
class Message {
  final Role role;
  final String content;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  const Message({
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
  });
}

/// A persisted turn in the chat agent's ContextStore. A superset of
/// `Message` with id + timestamp (so we can restore chronological order
/// on cold boot).
class ChatTurn {
  final String id;
  final Role role;
  final String text;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  final int timestamp; // millis since epoch

  ChatTurn({
    required this.id,
    required this.role,
    required this.text,
    this.toolCalls = const [],
    this.toolCallId,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  Message toMessage() => Message(
        role: role,
        content: text,
        toolCalls: toolCalls,
        toolCallId: toolCallId,
      );
}

/// Streaming events. Same four shapes the native SDK emits.
sealed class Delta {
  const Delta();
}

class DeltaText extends Delta {
  final String chunk;
  const DeltaText(this.chunk);
}

class DeltaToolCallStart extends Delta {
  final String id;
  final String name;
  const DeltaToolCallStart({required this.id, required this.name});
}

class DeltaToolCallArgs extends Delta {
  final String id;
  final String chunk;
  const DeltaToolCallArgs({required this.id, required this.chunk});
}

class DeltaEnd extends Delta {
  const DeltaEnd();
}

/// Final reply shape from `LLMClient.complete`.
sealed class Completion {
  const Completion();
}

class CompletionText extends Completion {
  final Message message;
  const CompletionText(this.message);
}

class CompletionToolCalls extends Completion {
  final Message message;
  const CompletionToolCalls(this.message);
}

/// Status a chat agent can be in — drives the UI's disabled-state.
enum AgentStatus { idle, thinking, streaming, toolCalling, error }

class StreamingMessage {
  final String text;
  final String? activeTool;
  const StreamingMessage({this.text = '', this.activeTool});
}
