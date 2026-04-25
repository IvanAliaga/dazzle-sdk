// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// chat-kb-flutter — LLM + on-device vector search over a bundled FAQ
// corpus. Ingestion builds a Dazzle HNSW_SQ8 index from
// `assets/dazzle_faq.json`; the `search_kb` tool queries it. Mirrors
// samples/chat-kb/{android,ios} one-for-one.

import 'dart:async';
import 'dart:io';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:dazzle_samples_shared/dazzle_samples_shared.dart';
import 'package:flutter/material.dart';

import 'kb_corpus.dart';
import 'search_kb_tool.dart';

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
      threadId: 'chat-kb-default',
      llm: llm,
      tools: [SearchKbTool()],
      systemPrompt:
          'You are a Dazzle-SDK support assistant running entirely '
          'on-device. For ANY question about Dazzle, HNSW, '
          'sqlite-vec, sqlite-vector-ai, the four LLM adapters, or '
          'the benchmarks, call search_kb(query, k=5) first and '
          'ground your answer in the returned FAQ rows. If the '
          'question is clearly not about Dazzle, answer directly. '
          'Keep replies concise (2–4 sentences).',
    );

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dazzle · chat-kb',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.orange),
      home: ChatScreen(
        title: 'chat-kb',
        buildAgent: () async {
          await KbCorpus.loadIntoDazzle();
          return _buildAgent(await makeLLMClient());
        },
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
      sampleName: 'chat-kb',
      // Technical question about the SDK itself. The LLM issues a
      // search_kb(); the HNSW_SQ8 index returns FAQ rows with the
      // Dazzle vs sqlite-vec benchmark numbers; the final reply
      // grounds the comparison in those figures.
      llmScript: [
        const CompletionToolCalls(Message(
          role: Role.assistant,
          content: '',
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'search_kb',
              arguments: '{"query":"HNSW_SQ8 vs sqlite-vec mobile latency memory benchmark","k":5}',
            ),
          ],
        )),
        const CompletionText(Message(role: Role.assistant, content:
            'Dazzle uses HNSW_SQ8 — a proximity-graph index with 8-bit scalar quantization. On a Moto G35 benchmark with 10k × 384-d vectors, Dazzle runs queries in about 2.3 ms versus ~180 ms for sqlite-vec, which does a linear brute-force scan. The quantized index is also around 4× smaller than F32 — roughly 40 MB vs 160 MB for the same corpus — which matters on mid-tier devices where RAM is tight.')),
      ],
      userInputs: const [
        'Explain how Dazzle handles vector search on mobile and how it compares to sqlite-vec in terms of query latency and memory footprint.',
      ],
      prepare: KbCorpus.loadIntoDazzle,
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
      title: 'Dazzle · chat-kb · SAMPLE TEST',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.orange),
      home: _agent == null
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()))
          : ChatScreen.fromAgent(
              title: 'chat-kb · test',
              agent: _agent!,
              banner: SampleTestBanner(phase: _phase, detail: _detail),
            ),
    );
  }
}
