// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Shared chat UI — subscribes to the three ChatAgent observables and
// renders messages + streaming cursor + tool-call pill. Parity with
// samples/_shared/{android/ChatScreen.kt, ios/ChatView.swift,
// flutter/lib/src/chat_screen.dart}.

import React, {
  useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore,
} from 'react';
import {
  FlatList, StyleSheet, Text, TextInput, TouchableOpacity, View,
} from 'react-native';
import type {
  AgentStatus, ChatAgent, ChatTurn, StreamingMessage,
} from 'dazzle-react-native';

export function ChatScreen(props: { title: string; agent: ChatAgent }) {
  const { title, agent } = props;

  const messages  = useObservable(agent.messages);
  const streaming = useObservable(agent.streaming);
  const status    = useObservable(agent.status);

  const [input, setInput] = useState('');
  const listRef = useRef<FlatList>(null);

  useLayoutEffect(() => {
    // Auto-scroll to the bottom on any message / streaming update.
    setTimeout(() => {
      listRef.current?.scrollToEnd({ animated: true });
    }, 50);
  }, [messages.length, streaming?.text]);

  const onSend = async () => {
    const text = input.trim();
    if (!text || status !== 'idle') return;
    setInput('');
    try { await agent.send(text); } catch { /* swallowed — status=error */ }
  };

  return (
    <View style={styles.root}>
      <View style={styles.header}>
        <Text style={styles.title}>{title}</Text>
      </View>
      <FlatList
        ref={listRef}
        data={renderItems(messages, streaming)}
        keyExtractor={(x) => x.key}
        renderItem={({ item }) =>
            item.kind === 'turn'
              ? <MessageBubble turn={item.turn} />
              : item.kind === 'toolPill'
                ? <ToolPill toolName={item.toolName} />
                : <StreamingBubble s={item.streaming} />
        }
        contentContainerStyle={styles.list}
      />
      <View style={styles.inputRow}>
        <TextInput
          value={input}
          onChangeText={setInput}
          editable={status === 'idle'}
          placeholder="Ask Dazzle…"
          style={styles.input}
          onSubmitEditing={onSend}
          returnKeyType="send"
        />
        <TouchableOpacity
          onPress={status === 'idle' ? onSend : () => agent.cancel()}
          style={styles.sendBtn}>
          <Text style={styles.sendText}>{status === 'idle' ? '▶' : '■'}</Text>
        </TouchableOpacity>
      </View>
      {status !== 'idle' && status !== 'streaming' && (
        <Text style={styles.statusLine}>{status}</Text>
      )}
    </View>
  );
}

type Item =
  | { kind: 'turn'; key: string; turn: ChatTurn }
  | { kind: 'toolPill'; key: string; toolName: string }
  | { kind: 'streaming'; key: string; streaming: StreamingMessage };

function renderItems(
    messages: ChatTurn[], streaming: StreamingMessage | null): Item[] {
  // Shape the visible chat: user turns + real assistant text, and a
  // small "called <tool>" pill standing in for each tool round-trip.
  // Raw tool-JSON bubbles and empty assistant envelope turns are
  // hidden — they're internal context the LLM consumed, not messages
  // the user typed or read.
  const out: Item[] = [];
  for (let i = 0; i < messages.length; i++) {
    const t = messages[i];
    if (t.role === 'tool') continue; // raw JSON — hidden
    if (t.role === 'assistant' && !t.text) {
      // Empty assistant envelope that just carried a tool-call.
      // Replace it with a compact pill labelled with the tool name.
      const nextTool = messages.slice(i + 1)
          .find((n) => n.role === 'tool');
      if (nextTool) {
        out.push({ kind: 'toolPill', key: t.id,
                   toolName: extractToolName(t) ?? 'tool' });
      }
      continue;
    }
    out.push({ kind: 'turn', key: t.id, turn: t });
  }
  if (streaming) {
    out.push({ kind: 'streaming', key: '__streaming', streaming });
  }
  return out;
}

function extractToolName(turn: ChatTurn): string | undefined {
  // ChatTurn's public shape doesn't expose toolCalls on the message
  // side consistently — peek defensively. Most runtimes stash it on
  // `(turn as any).toolCalls[0].name`.
  const tc = (turn as any).toolCalls?.[0];
  return tc?.name;
}

function ToolPill({ toolName }: { toolName: string }) {
  return (
    <View style={[styles.bubbleRow, styles.rowStart]}>
      <View style={styles.toolPill}>
        <Text style={styles.toolPillText}>⚙ called {toolName}</Text>
      </View>
    </View>
  );
}

function MessageBubble({ turn }: { turn: ChatTurn }) {
  const isUser = turn.role === 'user';
  return (
    <View style={[styles.bubbleRow,
                  isUser ? styles.rowEnd : styles.rowStart]}>
      <View style={[styles.bubble,
                    isUser ? styles.bubbleUser : styles.bubbleAssistant]}>
        <Text style={isUser ? styles.bubbleTextUser : styles.bubbleText}>
          {turn.text || '…'}
        </Text>
      </View>
    </View>
  );
}

function StreamingBubble({ s }: { s: StreamingMessage }) {
  return (
    <View style={[styles.bubbleRow, styles.rowStart]}>
      <View style={[styles.bubble, styles.bubbleAssistant]}>
        {s.activeTool && (
          <Text style={styles.label}>calling {s.activeTool}…</Text>
        )}
        <Text style={styles.bubbleText}>
          {s.text ? `${s.text}▍` : '▍'}
        </Text>
      </View>
    </View>
  );
}

// ── Bridging ChatAgent's tiny Observable<T> to React ───────────────

function useObservable<T>(obs: { value: T;
                                 subscribe(l: (v: T) => void): () => void }): T {
  return useSyncExternalStore(
    (cb) => obs.subscribe(() => cb()),
    () => obs.value,
    () => obs.value,
  );
}

const styles = StyleSheet.create({
  root:       { flex: 1, backgroundColor: '#fff' },
  header:     { padding: 14, borderBottomColor: '#e0e0e0',
                borderBottomWidth: StyleSheet.hairlineWidth,
                backgroundColor: '#f3f3f3' },
  title:      { fontSize: 18, fontWeight: '600' },
  list:       { padding: 12, gap: 6 },
  bubbleRow:  { flexDirection: 'row', marginVertical: 3 },
  rowStart:   { justifyContent: 'flex-start' },
  rowEnd:     { justifyContent: 'flex-end' },
  bubble:     { maxWidth: 280, padding: 10, borderRadius: 12 },
  bubbleUser:       { backgroundColor: '#4460d3' },
  bubbleAssistant:  { backgroundColor: '#e7e7e7' },
  bubbleText:       { color: '#2a2a2a' },
  bubbleTextUser:   { color: '#fff' },
  label:      { fontSize: 11, color: '#666', marginBottom: 2 },
  toolPill:   { backgroundColor: '#fff4d5', paddingHorizontal: 10,
                paddingVertical: 4, borderRadius: 10 },
  toolPillText: { fontSize: 11, color: '#806300', fontStyle: 'italic' },
  inputRow:   { flexDirection: 'row', padding: 10, alignItems: 'center',
                borderTopColor: '#e0e0e0', borderTopWidth: StyleSheet.hairlineWidth },
  input:      { flex: 1, borderWidth: 1, borderColor: '#c9c9c9',
                borderRadius: 8, paddingHorizontal: 10, paddingVertical: 8 },
  sendBtn:    { width: 40, height: 40, marginLeft: 8, borderRadius: 20,
                backgroundColor: '#4460d3', alignItems: 'center',
                justifyContent: 'center' },
  sendText:   { color: '#fff', fontSize: 16, fontWeight: '600' },
  statusLine: { padding: 6, textAlign: 'center', color: '#666' },
});
