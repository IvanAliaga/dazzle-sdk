// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// chat-memory-rn — React Native port of samples/chat-memory. Pure
// conversational memory, zero RAG. Every user + assistant turn is
// persisted as a Dazzle hash; the ChatAgent restores prior history on
// cold boot.
//
// Two entry paths:
//   1. SAMPLE_TEST=1 (via env / adb extras / iOS launch-env) — runs
//      the scripted FakeLLMClient harness, writes the JSON report to
//      the app's document dir, exits the process. Used by
//      samples/_scripts/test_rn_{android,ios}.sh.
//   2. Normal interactive run — boots Dazzle, wires an LLMClient
//      picked by LLMAdapter (see samples/_shared/rn/llmAdapter.ts),
//      shows the shared ChatScreen.

import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator, StatusBar, StyleSheet, Text, View,
} from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import {
  ChatAgent, DazzleServer, LLMClient,
} from 'dazzle-react-native';

import { ChatScreen } from './src/ChatScreen';
import { isDemoFallback, makeLLMClient } from './src/llmAdapter';
import {
  isSampleTestMode, runSampleTest, SampleTestConfig,
} from './src/sampleTestRunner';

async function buildAgent(llm: LLMClient): Promise<ChatAgent> {
  return new ChatAgent({
    threadId:     'chat-memory-default',
    llm,
    systemPrompt:
      'You are Dazzle, a friendly on-device assistant. Keep replies ' +
      'short and conversational (1–3 sentences).',
  });
}

export default function App() {
  const [agent, setAgent] = useState<ChatAgent | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Test-mode banner visible above the ChatScreen while the scripted
  // conversation plays out — so the viewer can SEE the sample is
  // actually conversing, not just hand-waving at a green JSON file.
  const [testPhase, setTestPhase] = useState<
      'preparing' | 'running' | 'completed' | 'failed' | null>(null);
  const [testDetail, setTestDetail] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        await DazzleServer.shared.start();
        if (isSampleTestMode()) {
          const cfg: SampleTestConfig = {
            sampleName: 'chat-memory',
            // Two substantive turns that demonstrate persistence: the
            // user states identity + project in turn 1, the assistant
            // acknowledges, and turn 2 asks the assistant to recall
            // both. The "remembered" final reply proves Dazzle
            // restored the prior turn's context on the fresh LLM call.
            llmScript: [
              { type: 'text', message: { role: 'assistant',
                  content:
                      "Noted, Ivan. Dazzle — embedded DB with HNSW vector search for on-device LLM agents. I'll keep this context." } },
              { type: 'text', message: { role: 'assistant',
                  content:
                      "Yes — you're Ivan Aliaga, working on Dazzle, an embedded database with HNSW vector search for on-device LLM agents. What would you like to do next?" } },
            ],
            userInputs: [
              "Hi, I'm Ivan Aliaga. I'm building Dazzle — an embedded database with HNSW vector search for on-device LLM agents. Please remember this.",
              'Do you remember who I am and what I\'m working on?',
            ],
            prepare: async () => {},
            buildAgent,
            onAgentReady: (a) => setAgent(a),
            onStatusChange: (phase, detail) => {
              setTestPhase(phase);
              if (detail) setTestDetail(detail);
            },
          };
          await runSampleTest(cfg);
          return;
        }
        const llm = await makeLLMClient();
        setAgent(await buildAgent(llm));
      } catch (e: any) {
        setError(e?.message ?? String(e));
      }
    })();
    return () => { agent?.close(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <SafeAreaProvider>
      <StatusBar barStyle="default" />
      <View style={styles.container}>
        {error ? (
          <View style={styles.center}>
            <Text style={styles.err}>Couldn't start</Text>
            <Text style={styles.errBody}>{error}</Text>
          </View>
        ) : agent ? (
          <>
            {testPhase && (
              <View style={[
                  styles.testBanner,
                  testPhase === 'failed' && styles.testBannerFail,
                  testPhase === 'completed' && styles.testBannerOk,
              ]}>
                <Text style={styles.testBannerText}>
                  {testPhase === 'preparing'  && '⏳ SAMPLE TEST — preparing…'}
                  {testPhase === 'running'    && '▶︎ SAMPLE TEST — scripted run in progress'}
                  {testPhase === 'completed'  && `✓ SAMPLE TEST — complete${testDetail ? ` (${testDetail})` : ''}`}
                  {testPhase === 'failed'     && `✗ SAMPLE TEST — failed${testDetail ? `: ${testDetail}` : ''}`}
                </Text>
              </View>
            )}
            {!testPhase && isDemoFallback && (
              <View style={styles.demoBanner}>
                <Text style={styles.demoBannerText}>
                  Demo mode — set OPENAI_API_KEY or HF_TOKEN, or edit
                  src/llmAdapter.ts to plug in a real LLM.
                </Text>
              </View>
            )}
            <ChatScreen title="chat-memory" agent={agent} />
          </>
        ) : (
          <View style={styles.center}>
            <ActivityIndicator size="large" />
            <Text style={styles.msg}>Loading model + booting Dazzle…</Text>
          </View>
        )}
      </View>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  center:    { flex: 1, alignItems: 'center', justifyContent: 'center',
               padding: 16 },
  msg:       { marginTop: 12, color: '#444', textAlign: 'center' },
  err:       { fontSize: 18, fontWeight: '600', marginBottom: 8 },
  errBody:   { color: '#a00', textAlign: 'center' },
  demoBanner:     { backgroundColor: '#fff4d5', padding: 10 },
  demoBannerText: { fontSize: 12, color: '#665500', textAlign: 'center' },
  testBanner:     { backgroundColor: '#1e3a8a', padding: 10 },
  testBannerOk:   { backgroundColor: '#166534' },
  testBannerFail: { backgroundColor: '#7f1d1d' },
  testBannerText: { color: '#fff', fontWeight: '600', textAlign: 'center' },
});
