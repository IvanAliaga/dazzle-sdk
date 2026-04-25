// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// LLMClient implementation over the OpenAI /v1/chat/completions REST
// shape. Works against OpenAI, Groq, HuggingFace Router, vLLM,
// Ollama, llama-server, Together, Mistral — any endpoint that speaks
// the same JSON body + SSE streaming shape.
//
// Pure Dart — no FFI needed, cloud is the bottleneck anyway.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/llm_client.dart';
import '../agent/message.dart';
import '../agent/tool.dart';

class OpenAICompatibleClient implements LLMClient {
  OpenAICompatibleClient({
    required this.baseURL,
    required String model,
    this.apiKey,
    this.extraHeaders = const {},
    this.temperature,
    this.maxTokens,
    http.Client? httpClient,
  })  : modelId = model,
        _model = model,
        _http = httpClient ?? http.Client();

  final Uri baseURL;
  final String _model;
  final String? apiKey;
  final Map<String, String> extraHeaders;
  final double? temperature;
  final int? maxTokens;
  final http.Client _http;

  @override
  final String modelId;

  @override
  Future<Completion> complete({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async {
    final body = _buildBody(messages, tools, stream: false);
    final resp = await _http.post(
      baseURL.resolve('chat/completions'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    _throwOnHttpError(resp);
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parseCompletionBlocking(decoded);
  }

  @override
  Stream<Delta> stream({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async* {
    final req = http.Request('POST', baseURL.resolve('chat/completions'));
    _headers().forEach((k, v) => req.headers[k] = v);
    req.body = jsonEncode(_buildBody(messages, tools, stream: true));

    final streamed = await _http.send(req);
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      throw StateError('HTTP ${streamed.statusCode}: $body');
    }

    final lines = streamed.stream.transform(utf8.decoder).transform(const LineSplitter());
    final toolIdByIdx = <int, String>{};
    final toolNameById = <String, String>{};

    await for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || !line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;

      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'] as List? ?? const [];
      if (choices.isEmpty) continue;
      final delta = (choices[0] as Map)['delta'] as Map? ?? const {};

      if (delta['content'] case final String text when text.isNotEmpty) {
        yield DeltaText(text);
      }
      if (delta['tool_calls'] case final List calls) {
        for (final callRaw in calls) {
          final call = callRaw as Map<String, dynamic>;
          final idx = call['index'] as int? ?? 0;
          final id = (call['id'] as String?) ?? toolIdByIdx[idx];
          if (id == null) continue;
          toolIdByIdx[idx] = id;

          final fn = call['function'] as Map<String, dynamic>?;
          if (fn != null) {
            if (fn['name'] case final String name) {
              if (!toolNameById.containsKey(id)) {
                toolNameById[id] = name;
                yield DeltaToolCallStart(id: id, name: name);
              }
            }
            if (fn['arguments'] case final String chunk when chunk.isNotEmpty) {
              yield DeltaToolCallArgs(id: id, chunk: chunk);
            }
          }
        }
      }
    }
    yield const DeltaEnd();
  }

  @override
  Future<void> close() async {
    _http.close();
  }

  // MARK: – Helpers

  Map<String, String> _headers() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      ...extraHeaders,
    };
    return h;
  }

  Map<String, dynamic> _buildBody(
      List<Message> messages, List<ToolDeclaration> tools,
      {required bool stream}) {
    return {
      'model': _model,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
      'stream': stream,
      'messages': messages.map(_encodeMessage).toList(),
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': jsonDecode(t.parameters.serialize()),
                  },
                })
            .toList(),
    };
  }

  Map<String, dynamic> _encodeMessage(Message m) {
    final out = <String, dynamic>{'role': m.role.wire, 'content': m.content};
    if (m.toolCallId != null) out['tool_call_id'] = m.toolCallId;
    if (m.toolCalls.isNotEmpty) {
      out['tool_calls'] = m.toolCalls
          .map((c) => {
                'id': c.id,
                'type': 'function',
                'function': {'name': c.name, 'arguments': c.arguments},
              })
          .toList();
    }
    return out;
  }

  Completion _parseCompletionBlocking(Map<String, dynamic> decoded) {
    final choices = decoded['choices'] as List? ?? const [];
    if (choices.isEmpty) {
      return CompletionText(Message(role: Role.assistant, content: ''));
    }
    final msg = (choices[0] as Map)['message'] as Map? ?? const {};
    final content = (msg['content'] as String?) ?? '';
    final calls = (msg['tool_calls'] as List?) ?? const [];
    if (calls.isNotEmpty) {
      final decoded = calls
          .whereType<Map>()
          .map((c) => ToolCall(
                id: c['id'] as String? ?? '',
                name: (c['function'] as Map?)?['name'] as String? ?? '',
                arguments:
                    (c['function'] as Map?)?['arguments'] as String? ?? '{}',
              ))
          .toList();
      return CompletionToolCalls(Message(
        role: Role.assistant,
        content: content,
        toolCalls: decoded,
      ));
    }
    return CompletionText(Message(role: Role.assistant, content: content));
  }

  void _throwOnHttpError(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw StateError('HTTP ${resp.statusCode} from ${resp.request?.url}: ${resp.body}');
    }
  }
}
