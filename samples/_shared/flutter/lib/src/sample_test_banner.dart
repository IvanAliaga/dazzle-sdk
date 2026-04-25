// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Thin top-of-screen banner used by the sample-test mode of every
// Dazzle Flutter sample. Tracks the phase exposed by `runSampleTest`
// (`preparing` / `running` / `completed` / `failed`) and colours the
// strip so a human watching the device can see at a glance whether the
// scripted conversation actually played out, independently of the
// JSON report the harness later validates.

import 'package:flutter/material.dart';

class SampleTestBanner extends StatelessWidget {
  const SampleTestBanner({super.key, required this.phase, this.detail});

  final String phase;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final (bg, text, icon) = _style(phase);
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              detail == null ? text : '$text  —  $detail',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  (Color, String, IconData) _style(String phase) {
    switch (phase) {
      case 'preparing':
        return (
          const Color(0xFF1E3A8A),
          'DEV SMOKE · scripted (no real LLM) · preparing',
          Icons.hourglass_top,
        );
      case 'running':
        return (
          const Color(0xFF1E3A8A),
          'DEV SMOKE · scripted (no real LLM) · tap icon for Qwen',
          Icons.play_arrow,
        );
      case 'completed':
        return (
          const Color(0xFF166534),
          'DEV SMOKE · complete · app icon = real Qwen',
          Icons.check_circle,
        );
      case 'failed':
        return (
          const Color(0xFF7F1D1D),
          'DEV SMOKE · failed',
          Icons.error,
        );
      default:
        return (
          const Color(0xFF1E3A8A),
          phase,
          Icons.info,
        );
    }
  }
}
