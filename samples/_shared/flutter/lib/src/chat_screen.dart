// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Shared Material-3 chat screen. Every Dazzle Flutter sample imports
// this widget so the UX is identical across chat-memory-flutter,
// chat-iot-flutter, chat-kb-flutter. Matches the behaviour of
// samples/_shared/android/ChatScreen.kt and ios/ChatView.swift
// one-for-one — the sample owns the agent factory (`buildAgent`), this
// widget handles scrolling, streaming cursor, tool-call pill, and
// error surfacing.

import 'package:dazzle_flutter/dazzle_flutter.dart';
import 'package:flutter/material.dart';

typedef BuildAgent = Future<ChatAgent> Function();

class ChatScreen extends StatefulWidget {
  /// Factory variant — the widget calls [buildAgent] the first time it
  /// mounts, which is what the production app path uses.
  const ChatScreen({
    super.key,
    required this.title,
    required this.buildAgent,
    this.banner,
  })  : agent = null;

  /// Pre-built-agent variant. Used by the sample-test mode (see
  /// `sample_test_runner.dart`) where the harness constructs the
  /// ChatAgent via a FakeLLMClient and wants the UI to render live.
  /// Also takes an optional [banner] widget to overlay above the
  /// chat stream (e.g. the "SAMPLE TEST — running…" strip).
  const ChatScreen.fromAgent({
    super.key,
    required this.title,
    required ChatAgent this.agent,
    this.banner,
  })  : buildAgent = null;

  final String title;
  final BuildAgent? buildAgent;
  final ChatAgent? agent;
  final Widget? banner;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  ChatAgent? _agent;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.agent != null) {
      _agent = widget.agent;
    } else {
      _bootstrap();
    }
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    if (widget.agent != null && widget.agent != old.agent) {
      setState(() => _agent = widget.agent);
    }
  }

  Future<void> _bootstrap() async {
    try {
      final a = await widget.buildAgent!();
      if (!mounted) return;
      setState(() => _agent = a);
    } catch (e, st) {
      debugPrint('ChatScreen bootstrap failed: $e\n$st');
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    // Only close the agent if WE built it — in `ChatScreen.fromAgent`
    // mode the outer caller owns the lifecycle (e.g. the test harness).
    if (widget.buildAgent != null) {
      _agent?.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      body: _agent != null
          ? Column(children: [
              if (widget.banner != null) widget.banner!,
              Expanded(child: _ChatBody(agent: _agent!)),
            ])
          : _error != null
              ? _ErrorBanner(error: _error!)
              : const _LoadingStub(),
    );
  }
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({required this.agent});
  final ChatAgent agent;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.agent.messages.addListener(_autoScroll);
    widget.agent.streaming.addListener(_autoScroll);
  }

  @override
  void dispose() {
    widget.agent.messages.removeListener(_autoScroll);
    widget.agent.streaming.removeListener(_autoScroll);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _onSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await widget.agent.send(text);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentStatus>(
      valueListenable: widget.agent.status,
      builder: (context, status, _) {
        return Column(
          children: [
            Expanded(
              child: ValueListenableBuilder<List<ChatTurn>>(
                valueListenable: widget.agent.messages,
                builder: (context, messages, _) {
                  return ValueListenableBuilder<StreamingMessage?>(
                    valueListenable: widget.agent.streaming,
                    builder: (context, streaming, _) {
                      // Hide raw tool-JSON bubbles and empty assistant
                      // envelopes. Stand in for each tool round-trip
                      // with a compact "called <tool>" pill so the
                      // chat reads like a conversation, not a JSON
                      // dump — while still showing the workflow.
                      final items = <Widget>[];
                      for (var i = 0; i < messages.length; i++) {
                        final t = messages[i];
                        if (t.role == Role.tool) continue;
                        if (t.role == Role.assistant && t.text.isEmpty) {
                          final hasNextTool = messages
                              .skip(i + 1)
                              .any((n) => n.role == Role.tool);
                          if (hasNextTool) {
                            items.add(_ToolPill(
                                toolName: t.toolCalls.isNotEmpty
                                    ? t.toolCalls.first.name
                                    : 'tool'));
                          }
                          continue;
                        }
                        items.add(_MessageBubble(turn: t));
                      }
                      if (streaming != null) {
                        items.add(_StreamingBubble(m: streaming));
                      }
                      return ListView.separated(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, i) => items[i],
                      );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: status == AgentStatus.idle,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(
                          hintText: 'Ask Dazzle…',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _onSend(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: status == AgentStatus.idle
                          ? _onSend
                          : widget.agent.cancel,
                      icon: Icon(status == AgentStatus.idle
                          ? Icons.send
                          : Icons.stop),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.turn});
  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = turn.role == Role.user;

    final bg = switch (turn.role) {
      Role.user      => cs.primary,
      Role.assistant => cs.surfaceContainerHighest,
      Role.tool      => cs.tertiaryContainer,
      Role.system    => cs.errorContainer.withValues(alpha: 0.3),
    };
    final fg = isUser ? cs.onPrimary : cs.onSurfaceVariant;

    return Row(
      mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (turn.role == Role.tool)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('tool reply',
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              Material(
                borderRadius: BorderRadius.circular(12),
                color: bg,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(turn.text.isEmpty ? '…' : turn.text,
                      style: TextStyle(color: fg)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ToolPill extends StatelessWidget {
  const _ToolPill({required this.toolName});
  final String toolName;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4D5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '⚙ called $toolName',
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF806300),
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.m});
  final StreamingMessage m;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m.activeTool != null)
                Text('calling ${m.activeTool}…',
                    style: Theme.of(context).textTheme.labelSmall),
              Material(
                borderRadius: BorderRadius.circular(12),
                color: cs.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(m.text.isEmpty ? '▍' : '${m.text}▍'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoadingStub extends StatelessWidget {
  const _LoadingStub();
  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Loading model + booting Dazzle…'),
          ],
        ),
      );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});
  final Object error;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Couldn't start",
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('$error',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
