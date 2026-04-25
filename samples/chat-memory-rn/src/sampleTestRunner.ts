// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Headless e2e harness — scripts a FakeLLMClient, runs the ChatAgent
// end to end, writes a JSON report to the app's Documents. Matches
// samples/_shared/{android,ios,flutter}/sample_test_runner.* one-for-
// one so the cross-platform test emits the same report shape.
//
// React Native has no `path_provider`. On Android we use
// DocumentsContract via NativeModules; on iOS we use the standard
// $HOME/Documents convention. The `writeFile` NativeModule lives in
// the dazzle-react-native plugin so samples don't have to pull a
// filesystem library.

import { NativeModules, Platform } from 'react-native';
import {
  AgentStatus, ChatAgent, Completion, DazzleServer, FakeLLMClient,
  LLMClient, exitProcess,
} from 'dazzle-react-native';

import { makeLLMClient } from './llmAdapter';

const { DazzleReactNative } = NativeModules;


export interface SampleTestConfig {
  sampleName: string;
  llmScript: Completion[];
  userInputs: string[];
  prepare: () => Promise<void>;
  buildAgent: (llm: LLMClient) => Promise<ChatAgent>;
  /** Called as soon as the agent is built, so the UI can subscribe
   *  to its observable streams and render the live chat — makes the
   *  automated run visually verifiable instead of invisible
   *  background work. */
  onAgentReady?: (agent: ChatAgent) => void;
  /** Pause before each user input so the on-device viewer can see
   *  each turn land. Defaults to 1200 ms. */
  delayBetweenTurnsMs?: number;
  /** Pause after the last turn completes, before the process is
   *  killed. Long enough for a human to read the final reply.
   *  Defaults to 5000 ms. */
  postRunDisplayMs?: number;
  /** Banner state callback — signals the outer app when the test
   *  completes, so the UI can overlay a "TEST DONE" banner. */
  onStatusChange?: (phase: 'preparing' | 'running' | 'completed' | 'failed',
                    detail?: string) => void;
}

export interface SampleTestReport {
  sample_name: string;
  elapsed_ms: number;
  turn_count: number;
  user_turns: number;
  assistant_turns: number;
  tool_turns: number;
  llm_call_count: number;
  last_assistant_text: string;
  last_tool_text: string;
  status: 'pass' | 'fail';
  error: string | null;
}

/** Is this app booted in test mode? Accepts either the Dart-define-
 *  style config file (set by `metro --dart-define-equivalent`), or
 *  `DAZZLE_SAMPLE_TEST=1` in the process env (launched via adb/
 *  devicectl). */
export function isSampleTestMode(): boolean {
  if ((global as any).DAZZLE_SAMPLE_TEST === '1') return true;
  if (Platform.OS === 'android' || Platform.OS === 'ios') {
    // NativeModules helper — we ship a small getEnv to read the iOS
    // launch-env / Android intent extras back into JS.
    try {
      const envFlag = DazzleReactNative?.getEnv?.('DAZZLE_SAMPLE_TEST');
      if (envFlag === '1') return true;
    } catch { /* no-op */ }
  }
  return false;
}

export async function runSampleTest(cfg: SampleTestConfig): Promise<boolean> {
  const started = Date.now();
  const fake = new FakeLLMClient('fake:test', cfg.llmScript);
  // DAZZLE_REAL_LLM=1 (intent extra or env) → use the real adapter.
  let useReal = false;
  try {
    const v = DazzleReactNative?.getEnv?.('DAZZLE_REAL_LLM');
    useReal = v === '1';
  } catch {}
  const delayBetweenTurns = cfg.delayBetweenTurnsMs ?? 1200;
  const postRunDisplay    = cfg.postRunDisplayMs    ?? 5000;
  let agent: ChatAgent | null = null;
  try {
    cfg.onStatusChange?.('preparing');
    await DazzleServer.shared.waitForReady(5_000);
    await cfg.prepare();
    const llm: LLMClient = useReal ? await makeLLMClient() : fake;
    if (useReal) console.log('[sample_test] DAZZLE_REAL_LLM=1 → real LLMAdapter');
    agent = await cfg.buildAgent(llm);
    cfg.onAgentReady?.(agent);

    // Small breather before the first send so the UI has a frame to
    // mount the ChatScreen bound to this agent.
    await new Promise<void>((r) => setTimeout(r, 400));
    cfg.onStatusChange?.('running');

    for (let i = 0; i < cfg.userInputs.length; i++) {
      const input = cfg.userInputs[i];
      if (i > 0) {
        // Inter-turn pause so the viewer can read the previous
        // assistant reply before the next user message lands.
        await new Promise<void>((r) => setTimeout(r, delayBetweenTurns));
      }
      await agent.send(input);
      const deadline = Date.now() + (useReal ? 90_000 : 30_000);
      while (agent.status.value !== 'idle') {
        if (Date.now() > deadline) {
          throw new Error(`turn '${input}' timed out after 30 s`);
        }
        await new Promise<void>((r) => setTimeout(r, 100));
      }
    }

    const messages = agent.messages.value;
    const assistantTurns = messages.filter((t) => t.role === 'assistant');
    const toolTurns = messages.filter((t) => t.role === 'tool');

    cfg.onStatusChange?.('completed',
        `${messages.length} turns · ${Date.now() - started} ms`);

    // Visible breathing time so the user can read the final reply
    // before the harness yanks the process.
    await new Promise<void>((r) => setTimeout(r, postRunDisplay));

    await writeReport({
      sample_name: cfg.sampleName,
      elapsed_ms: Date.now() - started,
      turn_count: messages.length,
      user_turns: messages.filter((t) => t.role === 'user').length,
      assistant_turns: assistantTurns.length,
      tool_turns: toolTurns.length,
      llm_call_count: fake.callCount,
      last_assistant_text: assistantTurns.at(-1)?.text ?? '',
      last_tool_text: toolTurns.at(-1)?.text ?? '',
      status: 'pass',
      error: null,
    });
    return true;
  } catch (e: any) {
    cfg.onStatusChange?.('failed', e?.message ?? String(e));
    await new Promise<void>((r) => setTimeout(r, 2000));
    await writeReport({
      sample_name: cfg.sampleName,
      elapsed_ms: Date.now() - started,
      turn_count: 0, user_turns: 0, assistant_turns: 0, tool_turns: 0,
      llm_call_count: 0,
      last_assistant_text: '', last_tool_text: '',
      status: 'fail',
      error: e?.message ?? String(e),
    });
    return false;
  } finally {
    await agent?.close();
  }
}

async function writeReport(report: SampleTestReport): Promise<void> {
  const json = JSON.stringify(report, null, 2);
  const marker = `${Date.now()} ${report.status === 'pass' ? 'ok' : 'error'} sample_test_${report.sample_name}\n`;
  try {
    await DazzleReactNative.writeReport(report.sample_name, json, marker);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sample_test] writeReport failed', e);
  }
  // Kill the process so the next springboard tap starts on the real
  // chat UI instead of resuming the "Sample test completed" screen.
  try { await exitProcess(); } catch { /* ignore — already exiting */ }
}

/** Polling helper used by the sample entry point. */
export async function waitIdle(agent: ChatAgent): Promise<void> {
  while (agent.status.value !== 'idle') {
    await new Promise<void>((r) => setTimeout(r, 50));
  }
}

export type { AgentStatus };
