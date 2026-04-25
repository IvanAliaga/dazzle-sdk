// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// chat-kb-rn — LLM + on-device HNSW_SQ8 vector search over a bundled
// FAQ corpus. Ingestion builds the index from dazzle_faq.json; the
// search_kb tool embeds the user query and returns the top-k rows.

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
import { KbCorpus } from './src/kbCorpus';
import { SearchKbTool } from './src/searchKbTool';
import {
  isSampleTestMode, runSampleTest, SampleTestConfig,
} from './src/sampleTestRunner';

async function buildAgent(llm: LLMClient): Promise<ChatAgent> {
  return new ChatAgent({
    threadId: 'chat-kb-default',
    llm,
    tools: [new SearchKbTool()],
    systemPrompt:
      'You are a Dazzle-SDK support assistant running entirely ' +
      'on-device. For ANY question about Dazzle, HNSW, sqlite-vec, ' +
      'sqlite-vector-ai, the four LLM adapters, or the benchmarks, ' +
      'call search_kb(query, k=5) first and ground your answer in ' +
      'the returned FAQ rows. If the question is clearly not about ' +
      'Dazzle, answer directly. Keep replies concise (2–4 sentences).',
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
            sampleName: 'chat-kb',
            // Technical question about the SDK itself. The LLM issues
            // search_kb(); HNSW_SQ8 returns FAQ rows with the Dazzle
            // vs sqlite-vec benchmark numbers; the final reply
            // grounds the comparison in those concrete figures.
            llmScript: [
              { type: 'toolCalls', message: { role: 'assistant', content: '',
                toolCalls: [{ id: 'c1', name: 'search_kb',
                              arguments: '{"query":"HNSW_SQ8 vs sqlite-vec mobile latency memory benchmark","k":5}' }] } },
              { type: 'text', message: { role: 'assistant', content:
                  'Dazzle uses HNSW_SQ8 — a proximity-graph index with 8-bit scalar quantization. On a Moto G35 benchmark with 10k × 384-d vectors, Dazzle runs queries in about 2.3 ms versus ~180 ms for sqlite-vec, which does a linear brute-force scan. The quantized index is also around 4× smaller than F32 — roughly 40 MB vs 160 MB for the same corpus — which matters on mid-tier devices where RAM is tight.' } },
            ],
            userInputs: [
              'Explain how Dazzle handles vector search on mobile and how it compares to sqlite-vec in terms of query latency and memory footprint.',
            ],
            prepare: () => KbCorpus.loadIntoDazzle(),
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
        await KbCorpus.loadIntoDazzle();
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
            <ChatScreen title="chat-kb" agent={agent} />
          </>
        ) : (
          <View style={styles.center}>
            <ActivityIndicator size="large" />
            <Text style={styles.msg}>Indexing FAQ + booting Dazzle…</Text>
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
