// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// chat-memory-flutter — minimal Dazzle chat sample.
//
// No tools, no retrieval, no dataset — just an LLMClient plus Dazzle
// persisting every turn as a hash so the conversation survives app
// restarts and replays on cold boot. Mirrors samples/chat-memory/
// {android,ios} one-for-one.

import 'dart:async';
import 'dart:io';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:dazzle_samples_shared/dazzle_samples_shared.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DazzleServer.shared.start();

  if (isSampleTestMode()) {
    // Visible test mode — render the ChatScreen bound to the agent
    // the harness builds, so a human watching the device actually sees
    // the scripted conversation play out.
    runApp(const _TestApp());
    return;
  }

  runApp(const _App());
}

ChatAgent _buildAgent(LLMClient llm) => DazzleServer.shared.chatAgent(
      threadId: 'chat-memory-default',
      llm: llm,
      systemPrompt:
          'You are Dazzle, a friendly on-device assistant. Keep '
          'replies short and conversational (1–3 sentences).',
    );

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dazzle · chat-memory',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: ChatScreen(
        title: 'chat-memory',
        buildAgent: () async =>
            _buildAgent(await makeLLMClient()),
      ),
    );
  }
}

class _TestApp extends StatefulWidget {
  const _TestApp();
  @override
  State<_TestApp> createState() => _TestAppState();
}

class _TestAppState extends State<_TestApp> {
  ChatAgent? _agent;
  String _phase = 'preparing';
  String? _detail;

  @override
  void initState() {
    super.initState();
    _runTest();
  }

  Future<void> _runTest() async {
    final cfg = SampleTestConfig(
      sampleName: 'chat-memory',
      // Dev-smoke scripted replies. Real demos use the LLMAdapter
      // (Qwen GGUF) — tap the app icon normally.
      llmScript: [
        const CompletionText(Message(role: Role.assistant, content:
            "Noted, Ivan. Dazzle — embedded DB with HNSW vector search for on-device LLM agents. I'll keep this context.")),
        const CompletionText(Message(role: Role.assistant, content:
            "Yes — you're Ivan Aliaga, working on Dazzle, an embedded database with HNSW vector search for on-device LLM agents. What would you like to do next?")),
      ],
      userInputs: const [
        "Hi, I'm Ivan Aliaga. I'm building Dazzle — an embedded database with HNSW vector search for on-device LLM agents. Please remember this.",
        'Do you remember who I am and what I\'m working on?',
      ],
      prepare: () async {/* no-op */},
      buildAgent: (llm) async => _buildAgent(llm),
      onAgentReady: (a) {
        if (!mounted) return;
        setState(() => _agent = a);
      },
      onStatusChange: (phase, detail) {
        if (!mounted) return;
        setState(() { _phase = phase; _detail = detail; });
      },
    );
    await runSampleTest(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dazzle · chat-memory · SAMPLE TEST',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: _agent == null
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()))
          : ChatScreen.fromAgent(
              title: 'chat-memory · test',
              agent: _agent!,
              banner: SampleTestBanner(phase: _phase, detail: _detail),
            ),
    );
  }
}
