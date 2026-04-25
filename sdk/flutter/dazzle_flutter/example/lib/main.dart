// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Smoke-test app for dazzle_flutter. Boots Dazzle, round-trips a hash,
// times the RESP-free `getAllDirect` path, and prints each result on
// screen. Ship-shape to prove the full FFI + method-channel pipeline.

import 'package:flutter/material.dart';
import 'package:dazzle_flutter/dazzle_flutter.dart';

void main() {
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: _Home(), title: 'dazzle_flutter smoke');
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  String _log = 'booting Dazzle…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final sw = Stopwatch()..start();

      await DazzleServer.shared.start(
          config: const DazzleConfig(maxMemory: '32mb'));
      final bootMs = sw.elapsedMilliseconds;

      final dazzle = DazzleServer.shared.client();
      final hash = dazzle.hash('demo:turn:1');

      sw.reset();
      hash.setAll({'role': 'user', 'text': "What's the weather in Lima?"});
      final writeUs = sw.elapsedMicroseconds;

      sw.reset();
      final turn = hash.getAllDirect();
      final directUs = sw.elapsedMicroseconds;

      sw.reset();
      final turnResp = hash.getAll();
      final respUs = sw.elapsedMicroseconds;

      hash.deleteKey();

      setState(() {
        _log = [
          'boot               : ${bootMs}ms',
          'HSET x2            : ${writeUs}µs',
          'getAllDirect       : ${directUs}µs',
          'getAll (RESP)      : ${respUs}µs',
          '',
          'read-back:  $turn',
          'read-back (RESP):  $turnResp',
        ].join('\n');
      });
    } catch (e, st) {
      setState(() => _log = 'ERROR: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('dazzle_flutter smoke')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: SelectableText(
              _log,
              style: const TextStyle(fontFamily: 'Courier', fontSize: 13),
            ),
          ),
        ),
      );
}
