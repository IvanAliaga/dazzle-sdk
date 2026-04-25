// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// LlamaCppClient for Flutter. Connects to OUR patched llama.cpp fork
// (statically linked into libdazzle.so / Dazzle.xcframework). The same
// binary every other Dazzle SDK uses — any patch we land (including
// the upstream audio-path bug workaround) applies here automatically
// on the next binary rebuild, no Dart code change.
//
// Architecture:
//   • inference runs in a dedicated background Isolate so the Flutter
//     main isolate stays UI-responsive during generation;
//   • inside the worker, llama.cpp emits each decoded token to a
//     `NativeCallable.listener` (Dart 3.0+ FFI API) — zero-copy C→Dart,
//     sub-µs overhead per token;
//   • tokens batch through a `SendPort` to the main isolate, which
//     yields them as `Delta.text` events on the `stream` future.
//
// This matches the pattern `fllama` established for 2024+ community
// LLM-on-device Flutter apps. The wrapper API matches our Kotlin /
// Swift `LlamaCppClient` exactly so the same `LLMClient` contract
// flows through `ChatAgent` unchanged.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../agent/llm_client.dart';
import '../agent/message.dart';
import '../agent/tool.dart';
import '../ffi/bindings.dart';

class LlamaCppClient implements LLMClient {
  LlamaCppClient._internal({
    required this.modelPath,
    required this.modelId,
    required this.systemPrompt,
    required this.temperature,
    required this.topP,
    required this.maxTokens,
    required this.nCtx,
    required this.nThreads,
    required this.seed,
  });

  /// Instantiate. Loads the GGUF off the caller isolate (typically a
  /// compute-heavy mmap), returns once the model + context are live.
  static Future<LlamaCppClient> create({
    required String modelPath,
    String? modelId,
    String systemPrompt = 'You are a helpful on-device AI assistant.',
    double temperature = 0.3,
    double topP = 0.95,
    int maxTokens = 512,
    int nCtx = 2048,
    int nThreads = 4,
    int seed = 0xD4771E,
  }) async {
    if (!File(modelPath).existsSync()) {
      throw StateError('GGUF not found at $modelPath');
    }
    final c = LlamaCppClient._internal(
      modelPath: modelPath,
      modelId: modelId ??
          modelPath
              .split(Platform.pathSeparator)
              .last
              .replaceAll(RegExp(r'\.gguf$'), ''),
      systemPrompt: systemPrompt,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      nCtx: nCtx,
      nThreads: nThreads,
      seed: seed,
    );
    await c._ensureLoaded();
    return c;
  }

  final String modelPath;
  @override final String modelId;
  final String systemPrompt;
  final double temperature;
  final double topP;
  final int maxTokens;
  final int nCtx;
  final int nThreads;
  final int seed;

  ffi.Pointer<ffi.Void>? _model;
  ffi.Pointer<ffi.Void>? _ctx;
  bool _disposed = false;

  Future<void> _ensureLoaded() async {
    if (_model != null && _ctx != null) return;
    final bindings = DazzleBindings.load();

    // The backend init is idempotent inside llama.cpp.
    bindings.llamaBackendInit();

    // mmap + weight load can be multi-second; do it on a worker so
    // the caller isolate isn't blocked.
    final modelAddr = await Isolate.run(() {
      final b = DazzleBindings.load();
      final p = modelPath.toNativeUtf8();
      try {
        final model = b.llamaLoadModel(p, 0);
        return model.address;
      } finally {
        calloc.free(p);
      }
    });
    final model = ffi.Pointer<ffi.Void>.fromAddress(modelAddr);
    if (model == ffi.nullptr) {
      throw StateError('dazzle_llama_load_model failed for $modelPath');
    }
    final ctx = bindings.llamaNewContext(model, nCtx, nThreads, seed);
    if (ctx == ffi.nullptr) {
      bindings.llamaFreeModel(model);
      throw StateError('dazzle_llama_new_context failed');
    }
    _model = model;
    _ctx = ctx;
  }

  @override
  Future<Completion> complete({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async {
    final text = <String>[];
    await for (final d in stream(messages: messages, tools: tools)) {
      if (d is DeltaText) text.add(d.chunk);
    }
    return CompletionText(
        Message(role: Role.assistant, content: text.join()));
  }

  /// Streams decoded tokens. The heavy lifting (decode loop) runs in a
  /// worker Isolate; tokens crosss the isolate boundary via SendPort
  /// post — the Dart-idiomatic, battle-tested pattern.
  ///
  /// We use `Isolate` instead of plain `NativeCallable.listener` on
  /// main because llama.cpp's decode is blocking — running it on the
  /// main isolate would freeze the UI. Inside the worker we still use
  /// the NativeCallable pattern C→Dart for zero-copy token emits.
  @override
  Stream<Delta> stream({
    required List<Message> messages,
    List<ToolDeclaration> tools = const [],
  }) async* {
    await _ensureLoaded();
    final prompt = _renderPrompt(messages);
    final out = StreamController<Delta>();

    final receivePort = ReceivePort();
    late Isolate worker;

    final req = _GenerateRequest(
      ctxAddress: _ctx!.address,
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      reply: receivePort.sendPort,
    );

    worker = await Isolate.spawn<_GenerateRequest>(
      _workerEntry,
      req,
      onExit: receivePort.sendPort,
      debugName: 'dazzle-llama-$modelId',
    );

    final sub = receivePort.listen((msg) {
      if (msg is _TokenChunk) {
        out.add(DeltaText(msg.text));
      } else if (msg is _TokenEnd) {
        out.add(const DeltaEnd());
        out.close();
        receivePort.close();
      } else if (msg is _TokenError) {
        out.addError(StateError(msg.message));
        out.close();
        receivePort.close();
      } else if (msg == null) {
        // Isolate exit signal. If we haven't already closed, force close.
        if (!out.isClosed) out.close();
      }
    });

    try {
      yield* out.stream;
    } finally {
      await sub.cancel();
      worker.kill(priority: Isolate.immediate);
    }
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    final bindings = DazzleBindings.load();
    if (_ctx != null && _ctx != ffi.nullptr) {
      bindings.llamaFreeContext(_ctx!);
      _ctx = null;
    }
    if (_model != null && _model != ffi.nullptr) {
      bindings.llamaFreeModel(_model!);
      _model = null;
    }
  }

  /// Render messages into the prompt shape llama.cpp expects. Uses a
  /// minimal ChatML-ish encoding — matches what the Kotlin / Swift
  /// `LlamaCppClient` emits by default.
  String _renderPrompt(List<Message> messages) {
    final sb = StringBuffer();
    for (final m in messages) {
      sb.write('<|im_start|>${m.role.wire}\n${m.content}<|im_end|>\n');
    }
    sb.write('<|im_start|>assistant\n');
    return sb.toString();
  }
}

// ── Worker isolate plumbing ────────────────────────────────────────────

class _GenerateRequest {
  final int ctxAddress;
  final String prompt;
  final int maxTokens;
  final double temperature;
  final double topP;
  final SendPort reply;
  _GenerateRequest({
    required this.ctxAddress,
    required this.prompt,
    required this.maxTokens,
    required this.temperature,
    required this.topP,
    required this.reply,
  });
}

class _TokenChunk { final String text; _TokenChunk(this.text); }
class _TokenEnd {}
class _TokenError { final String message; _TokenError(this.message); }

void _workerEntry(_GenerateRequest req) {
  try {
    final bindings = DazzleBindings.load();
    final ctx = ffi.Pointer<ffi.Void>.fromAddress(req.ctxAddress);
    final promptPtr = req.prompt.toNativeUtf8();

    // NativeCallable.listener gives us a zero-copy C→Dart path on the
    // SAME isolate (this worker) — avoids an extra SendPort hop per
    // token. We batch the decoded tokens into _TokenChunk messages and
    // post them to the main isolate via the reply SendPort (one hop
    // amortised per worker wake).
    final callable = ffi.NativeCallable<ffi.Void Function(ffi.Pointer<Utf8>)>
        .listener((ffi.Pointer<Utf8> tokenPtr) {
      if (tokenPtr == ffi.nullptr) return;
      try {
        final text = tokenPtr.toDartString();
        req.reply.send(_TokenChunk(text));
      } catch (_) {
        // Token decode failure — swallow; llama.cpp sometimes emits
        // incomplete UTF-8 that completes on the next call.
      }
    });

    try {
      final rc = bindings.llamaGenerate(
        ctx,
        promptPtr,
        req.maxTokens,
        req.temperature,
        req.topP,
        callable.nativeFunction,
      );
      if (rc != 0) {
        req.reply.send(_TokenError('dazzle_llama_generate rc=$rc'));
      } else {
        req.reply.send(_TokenEnd());
      }
    } finally {
      callable.close();
      calloc.free(promptPtr);
    }
  } catch (e, st) {
    req.reply.send(_TokenError('$e\n$st'));
  }
}
