// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// chat-iot-rn — LLM grounded on a local IoT sensor-data corpus stored
// in Dazzle. The LLM calls `retrieve_anomalies(min_from, min_to)`, the
// tool reads a SortedSet keyed by `start_minute`, parses the JSON
// payload and feeds the rows back into the agent loop.

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
import { IotCorpus } from './src/iotCorpus';
import { RetrieveAnomaliesTool } from './src/retrieveAnomaliesTool';
import {
  isSampleTestMode, runSampleTest, SampleTestConfig,
} from './src/sampleTestRunner';

async function buildAgent(llm: LLMClient): Promise<ChatAgent> {
  return new ChatAgent({
    threadId: 'chat-iot-default',
    llm,
    tools: [new RetrieveAnomaliesTool()],
    systemPrompt:
      'You are a sensor-data analyst running entirely on-device ' +
      "against the user's local Dazzle store. When the user asks " +
      'about temperature, humidity, anomalies, or a specific time ' +
      'window, call the retrieve_anomalies tool with the minute ' +
      'range (dataset minute 0..2399). Use the JSON output to ground ' +
      "your answer — do NOT invent numbers. Keep replies concise " +
      '(2–4 sentences).',
  });
}

export default function App() {
  const [agent, setAgent] = useState<ChatAgent | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [testPhase, setTestPhase] = useState<
      'preparing' | 'running' | 'completed' | 'failed' | null>(null);
  const [testDetail, setTestDetail] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        await DazzleServer.shared.start();
        if (isSampleTestMode()) {
          const cfg: SampleTestConfig = {
            sampleName: 'chat-iot',
            // Analyst-style question over real sensor data. The LLM
            // emits retrieve_anomalies(0..800); the tool pulls real
            // rows from the on-device SortedSet (including the
            // minute-195 28.5°C spike); the LLM grounds its reply in
            // those specific rows.
            llmScript: [
              { type: 'toolCalls', message: { role: 'assistant', content: '',
                toolCalls: [{ id: 'c1', name: 'retrieve_anomalies',
                              arguments: '{"min_from":0,"min_to":800}' }] } },
              { type: 'text', message: { role: 'assistant', content:
                  'I found one thermal anomaly in the first 800 minutes: a brief temperature spike to 28.5°C around minute 195, lasting about 3 minutes. Outside that window the sensors stayed stable, averaging 22.1°C with humidity near 48%. The spike pattern is consistent with an interrupted ventilation cycle.' } },
            ],
            userInputs: [
              'Run an analysis on the sensor data covering the first 800 minutes of the day. Tell me whether there were any thermal anomalies, when they happened, and how the rest of the window behaved.',
            ],
            prepare: () => IotCorpus.loadIntoDazzle(),
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
        await IotCorpus.loadIntoDazzle();
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
            <ChatScreen title="chat-iot" agent={agent} />
          </>
        ) : (
          <View style={styles.center}>
            <ActivityIndicator size="large" />
            <Text style={styles.msg}>Loading IoT corpus + booting Dazzle…</Text>
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
