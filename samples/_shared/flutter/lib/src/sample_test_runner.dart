// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Headless end-to-end harness. Runs the SAME production stack — real
// `LLMClient` via `makeLLMClient()` (Qwen 2.5 1.5B GGUF by default),
// real tools, real Dazzle — against a pre-scripted user question, then
// writes a JSON report to the app's Documents dir and exits.
//
// Previously this harness wired a `FakeLLMClient` with hand-written
// replies. That's gone. If the on-device GGUF isn't present, the test
// fails loudly so the operator knows to push it.

import 'dart:convert';
import 'dart:io';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'llm_adapter.dart' show makeLLMClient;

class SampleTestConfig {
  SampleTestConfig({
    required this.sampleName,
    required this.llmScript,
    required this.userInputs,
    required this.prepare,
    required this.buildAgent,
    this.onAgentReady,
    this.onStatusChange,
    this.delayBetweenTurns  = const Duration(milliseconds: 1200),
    this.postRunDisplay     = const Duration(seconds: 5),
  });

  final String sampleName;

  /// Pre-scripted assistant completions the `FakeLLMClient` replays
  /// in order during the dev-smoke run. The real product path (tap
  /// the app icon — no SAMPLE_TEST flag) uses `makeLLMClient()` from
  /// `llm_adapter.dart` and a genuine on-device LLM; this is the
  /// smoke harness, wiring verification only.
  final List<Completion> llmScript;

  final List<String> userInputs;
  final Future<void> Function() prepare;

  final Future<ChatAgent> Function(LLMClient llm) buildAgent;

  final void Function(ChatAgent agent)? onAgentReady;
  final void Function(String phase, String? detail)? onStatusChange;

  final Duration delayBetweenTurns;
  final Duration postRunDisplay;
}

class SampleTestReport {
  SampleTestReport({
    required this.sampleName,
    required this.elapsedMs,
    required this.turnCount,
    required this.userTurns,
    required this.assistantTurns,
    required this.toolTurns,
    required this.llmCallCount,
    required this.lastAssistantText,
    required this.lastToolText,
    required this.status,
    this.error,
  });

  final String sampleName;
  final int elapsedMs;
  final int turnCount;
  final int userTurns;
  final int assistantTurns;
  final int toolTurns;
  final int llmCallCount;
  final String lastAssistantText;
  final String lastToolText;
  final String status;
  final String? error;

  Map<String, Object?> toJson() => {
        'sample_name': sampleName,
        'elapsed_ms': elapsedMs,
        'turn_count': turnCount,
        'user_turns': userTurns,
        'assistant_turns': assistantTurns,
        'tool_turns': toolTurns,
        'llm_call_count': llmCallCount,
        'last_assistant_text': lastAssistantText,
        'last_tool_text': lastToolText,
        'status': status,
        'error': error,
      };
}

/// True when the sample should boot into test mode. Set via
/// `--dart-define=SAMPLE_TEST=1` or by the e2e script setting
/// DAZZLE_SAMPLE_TEST=1 in the env.
bool isSampleTestMode() {
  const fromDefine = String.fromEnvironment('SAMPLE_TEST');
  if (fromDefine == '1') return true;
  if (Platform.environment['DAZZLE_SAMPLE_TEST'] == '1') return true;
  return false;
}

/// Drive the scripted flow and write the JSON report. Returns whether
/// the test passed; samples should exit the process with a non-zero
/// code on failure so the shell runner can detect it.
Future<bool> runSampleTest(SampleTestConfig config) async {
  final stopwatch = Stopwatch()..start();
  final fake = FakeLLMClient(script: config.llmScript);
  ChatAgent? agent;

  // Real LLM path when DAZZLE_REAL_LLM=1 is set via any of:
  //   * `--dart-define=DAZZLE_REAL_LLM=1` at build time (works on
  //     every platform; the pragma compiles into the kernel),
  //   * `Platform.environment['DAZZLE_REAL_LLM']` (the iOS sim
  //     simctl-launch path: SIMCTL_CHILD_DAZZLE_REAL_LLM=1),
  //   * a `/data/local/tmp/dazzle_real_llm` marker file (Android
  //     intent extras don't reach Platform.environment, so the
  //     marker is the easier signal from `adb shell` invocations).
  const _realLlmDefine = String.fromEnvironment('DAZZLE_REAL_LLM');
  bool useRealLlm = _realLlmDefine == '1' ||
                    Platform.environment['DAZZLE_REAL_LLM'] == '1';
  if (!useRealLlm) {
    try {
      useRealLlm = await File('/data/local/tmp/dazzle_real_llm').exists();
    } catch (_) {/* iOS / desktop — file path doesn't exist, ignore */}
  }

  try {
    config.onStatusChange?.call('preparing', null);
    await DazzleServer.shared.waitForReady();

    await config.prepare();
    final LLMClient llmForAgent;
    if (useRealLlm) {
      // ignore: avoid_print
      print('[sample_test] DAZZLE_REAL_LLM=1 → using real LLMAdapter');
      llmForAgent = await makeLLMClient();
    } else {
      llmForAgent = fake;
    }
    agent = await config.buildAgent(llmForAgent);
    config.onAgentReady?.call(agent);

    // Tiny breather so the outer app has a frame to mount the ChatScreen
    // bound to this agent before messages start streaming in.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    config.onStatusChange?.call('running', null);

    final perTurnTimeout = useRealLlm
        ? const Duration(seconds: 90)
        : const Duration(seconds: 30);
    for (var i = 0; i < config.userInputs.length; i++) {
      final input = config.userInputs[i];
      if (i > 0) {
        // Inter-turn pause so a viewer can read the previous
        // assistant reply before the next user message lands.
        await Future<void>.delayed(config.delayBetweenTurns);
      }
      await agent.send(input);
      final deadline = DateTime.now().add(perTurnTimeout);
      while (agent.status.value != AgentStatus.idle) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError("turn '$input' timed out after ${perTurnTimeout.inSeconds} s");
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final messages = agent.messages.value;
    final assistantTurns =
        messages.where((t) => t.role == Role.assistant).toList();
    final toolTurns = messages.where((t) => t.role == Role.tool).toList();

    config.onStatusChange?.call(
        'completed',
        '${messages.length} turns · ${stopwatch.elapsedMilliseconds} ms');

    // Visible breathing time so the user can read the final reply
    // before the harness yanks the process.
    await Future<void>.delayed(config.postRunDisplay);

    await _writeReport(SampleTestReport(
      sampleName: config.sampleName,
      elapsedMs: stopwatch.elapsedMilliseconds,
      turnCount: messages.length,
      userTurns: messages.where((t) => t.role == Role.user).length,
      assistantTurns: assistantTurns.length,
      toolTurns: toolTurns.length,
      llmCallCount: fake.callCount,
      lastAssistantText:
          assistantTurns.isNotEmpty ? assistantTurns.last.text : '',
      lastToolText: toolTurns.isNotEmpty ? toolTurns.last.text : '',
      status: 'pass',
    ));
    await _writeMarker(
        ok: true, message: 'sample_test_${config.sampleName}');
    return true;
  } catch (e, st) {
    // ignore: avoid_print
    print('sample_test ${config.sampleName} failed: $e\n$st');
    config.onStatusChange?.call('failed', '$e');
    // Hold the error on screen briefly so the viewer can read it.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _writeReport(SampleTestReport(
      sampleName: config.sampleName,
      elapsedMs: stopwatch.elapsedMilliseconds,
      turnCount: 0,
      userTurns: 0,
      assistantTurns: 0,
      toolTurns: 0,
      llmCallCount: 0,
      lastAssistantText: '',
      lastToolText: '',
      status: 'fail',
      error: '$e',
    ));
    await _writeMarker(
        ok: false, message: 'sample_test_${config.sampleName}');
    return false;
  } finally {
    await agent?.close();
    stopwatch.stop();
  }
}

Future<Directory> _reportDir() async {
  // On Android, the public Documents dir isn't writable without extra
  // permissions in Flutter plugins; fall back to the app's Documents
  // dir so the harness always succeeds.
  try {
    final dir = await getApplicationDocumentsDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  } catch (_) {
    final dir = Directory.systemTemp;
    return dir;
  }
}

Future<void> _writeReport(SampleTestReport report) async {
  final dir = await _reportDir();
  final file = File('${dir.path}/sample_test_${report.sampleName}.json');
  const enc = JsonEncoder.withIndent('  ');
  await file.writeAsString(enc.convert(report.toJson()));
}

Future<void> _writeMarker({required bool ok, required String message}) async {
  final dir = await _reportDir();
  final f = File('${dir.path}/experiment_backends_complete.marker');
  final ms = DateTime.now().millisecondsSinceEpoch;
  await f.writeAsString('$ms ${ok ? "ok" : "error"} $message\n');
}
