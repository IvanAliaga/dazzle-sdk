// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// chat-iot-flutter — LLM grounded on a local IoT sensor-data corpus
// stored in Dazzle. The LLM calls `retrieve_anomalies(min_from, min_to)`
// and gets back JSON rows from a SortedSet keyed by `start_minute`.
// Mirrors samples/chat-iot/{android,ios} exactly.

import 'dart:async';
import 'dart:io';

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:dazzle_samples_shared/dazzle_samples_shared.dart';
import 'package:flutter/material.dart';

import 'iot_corpus.dart';
import 'retrieve_anomalies_tool.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DazzleServer.shared.start();

  if (isSampleTestMode()) {
    // Visible test mode — render the ChatScreen bound to the agent
    // the harness builds, so a human watching the device actually sees
    // the scripted conversation play out. `runSampleTest` is invoked
    // from inside the widget's `initState` (via _TestApp) so the first
    // frame can paint before messages start streaming in.
    runApp(const _TestApp());
    return;
  }

  runApp(const _App());
}

ChatAgent _buildAgent(LLMClient llm) => DazzleServer.shared.chatAgent(
      threadId: 'chat-iot-default',
      llm: llm,
      tools: [RetrieveAnomaliesTool()],
      systemPrompt:
          'You are a sensor-data analyst running entirely on-device '
          "against the user's local Dazzle store. When the user asks "
          'about temperature, humidity, anomalies, or a specific time '
          'window, call the retrieve_anomalies tool with the minute '
          'range (dataset minute 0..2399). Use the tool\'s JSON '
          'output to ground your answer — do NOT invent numbers. '
          'Keep replies concise (2–4 sentences).',
    );

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dazzle · chat-iot',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: ChatScreen(
        title: 'chat-iot',
        buildAgent: () async {
          await IotCorpus.loadIntoDazzle();
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
      sampleName: 'chat-iot',
      // Analyst-style question over real sensor data. The LLM emits
      // retrieve_anomalies(0..800); the tool pulls the real rows from
      // the on-device SortedSet (including the minute-195 28.5°C
      // spike); the LLM grounds its numerical reply in those rows.
      llmScript: [
        const CompletionToolCalls(Message(
          role: Role.assistant,
          content: '',
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'retrieve_anomalies',
              arguments: '{"min_from":0,"min_to":800}',
            ),
          ],
        )),
        const CompletionText(Message(role: Role.assistant, content:
            'I found one thermal anomaly in the first 800 minutes: a brief temperature spike to 28.5°C around minute 195, lasting about 3 minutes. Outside that window the sensors stayed stable, averaging 22.1°C with humidity near 48%. The spike pattern is consistent with an interrupted ventilation cycle.')),
      ],
      userInputs: const [
        'Run an analysis on the sensor data covering the first 800 minutes of the day. Tell me whether there were any thermal anomalies, when they happened, and how the rest of the window behaved.',
      ],
      prepare: IotCorpus.loadIntoDazzle,
      buildAgent: (llm) async => _buildAgent(llm),
      onAgentReady: (a) {
        if (!mounted) return;
        setState(() => _agent = a);
      },
      onStatusChange: (phase, detail) {
        if (!mounted) return;
        setState(() {
          _phase = phase;
          _detail = detail;
        });
      },
    );
    await runSampleTest(cfg);
    // Report written + post-run display elapsed — exit so the harness
    // sees the marker and moves on to the next sample. Brief buffer
    // so the fsync flushes before the process dies.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dazzle · chat-iot · SAMPLE TEST',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: _agent == null
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()))
          : ChatScreen.fromAgent(
              title: 'chat-iot · test',
              agent: _agent!,
              banner: SampleTestBanner(phase: _phase, detail: _detail),
            ),
    );
  }
}
