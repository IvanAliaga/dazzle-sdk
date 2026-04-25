// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// OpenAI-compatible HTTP client — pure JS over fetch + line-based SSE.
// Works with any endpoint that speaks `POST /v1/chat/completions` with
// the OpenAI JSON shape (OpenAI, HF Router, Ollama, vLLM, Groq, …).

import { Completion, Delta, Message, Role } from '../agent/message';
import { LLMClient } from '../agent/llmClient';
import { ToolDeclaration, serializeSchema } from '../agent/tool';

export interface OpenAICompatibleOptions {
  baseURL: string;
  model: string;
  apiKey?: string;
  extraHeaders?: Record<string, string>;
  temperature?: number;
  maxTokens?: number;
  fetchImpl?: typeof fetch;
}

export class OpenAICompatibleClient implements LLMClient {
  readonly modelId: string;
  private readonly baseURL: string;
  private readonly model: string;
  private readonly apiKey?: string;
  private readonly extraHeaders: Record<string, string>;
  private readonly temperature?: number;
  private readonly maxTokens?: number;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: OpenAICompatibleOptions) {
    this.baseURL = opts.baseURL.replace(/\/+$/, '');
    this.model = opts.model;
    this.modelId = opts.model;
    this.apiKey = opts.apiKey;
    this.extraHeaders = opts.extraHeaders ?? {};
    this.temperature = opts.temperature;
    this.maxTokens = opts.maxTokens;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async complete(opts: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): Promise<Completion> {
    const body = this.buildBody(opts.messages, opts.tools ?? [], false);
    const resp = await this.fetchImpl(`${this.baseURL}/chat/completions`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(body),
    });
    // Read body once. Some RN fetch polyfills set resp.ok = false
    // for chunked-encoding 200s — check status directly instead.
    const raw = await resp.text();
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`OpenAI HTTP ${resp.status}: ${raw}`);
    }
    // HF Router (Groq) ignores `stream:false` and always emits SSE.
    // Detect by the leading `data: ` and fold the chunks into a
    // single completion. Plain JSON path is the OpenAI / Ollama
    // happy path.
    const json = raw.trimStart().startsWith('data:')
        ? foldSseChunks(raw)
        : JSON.parse(raw);
    const choice = json.choices?.[0];
    const msg = choice?.message ?? choice?.delta ?? {};
    if (msg.tool_calls?.length) {
      return {
        type: 'toolCalls',
        message: {
          role: 'assistant',
          content: msg.content ?? '',
          toolCalls: msg.tool_calls.map((c: any) => ({
            id: c.id,
            name: c.function?.name ?? '',
            arguments: c.function?.arguments ?? '{}',
          })),
        },
      };
    }
    return {
      type: 'text',
      message: { role: 'assistant', content: msg.content ?? '' },
    };
  }

  async *stream(opts: {
    messages: Message[]; tools?: ToolDeclaration[];
  }): AsyncIterable<Delta> {
    const body = this.buildBody(opts.messages, opts.tools ?? [], true);
    const dbg = !!(globalThis as any).DAZZLE_DEBUG_LLM_BODY;
    if (dbg) {
      // eslint-disable-next-line no-console
      console.log('[DAZZLE_DEBUG] LLM body =', JSON.stringify(body));
    }
    const resp = await this.fetchImpl(`${this.baseURL}/chat/completions`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(body),
    });
    if (dbg) {
      // eslint-disable-next-line no-console
      console.log('[DAZZLE_DEBUG] resp.status =', resp.status,
                  'body=', resp.body ? 'present' : 'null',
                  'getReader=', typeof (resp.body as any)?.getReader);
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`OpenAI HTTP ${resp.status}: ${await resp.text()}`);
    }
    // React Native's fetch polyfill returns `resp.body === null` even
    // for 200s — it doesn't ship a streaming ReadableStream. Fall back
    // to buffered text + chunk-as-SSE so we still get incremental
    // semantics (the agent doesn't care if all deltas land in one tick
    // for a 256-token reply).
    const activeCalls = new Map<number, { id: string; name: string }>();
    if (!resp.body || typeof (resp.body as any).getReader !== 'function') {
      const raw = await resp.text();
      if (dbg) {
        // eslint-disable-next-line no-console
        console.log('[DAZZLE_DEBUG] buffered SSE bytes =', raw.length,
                    'head=', raw.slice(0, 220));
      }
      yield* parseSseChunks(raw, activeCalls);
      return;
    }
    const reader = (resp.body as any).getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let idx: number;
      while ((idx = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (!line || !line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (payload === '[DONE]') { yield { type: 'end' }; return; }
        let data: any;
        try { data = JSON.parse(payload); } catch { continue; }
        const delta = data.choices?.[0]?.delta ?? {};
        if (typeof delta.content === 'string' && delta.content.length) {
          yield { type: 'text', chunk: delta.content };
        }
        if (Array.isArray(delta.tool_calls)) {
          for (const c of delta.tool_calls) {
            const idx2 = c.index ?? 0;
            if (c.id || c.function?.name) {
              const prev = activeCalls.get(idx2);
              const id   = c.id ?? prev?.id ?? `call_${idx2}`;
              const name = c.function?.name ?? prev?.name ?? '';
              if (!prev || prev.id !== id) {
                activeCalls.set(idx2, { id, name });
                yield { type: 'toolCallStart', id, name };
              }
            }
            if (c.function?.arguments) {
              const prev = activeCalls.get(idx2);
              if (prev) {
                yield { type: 'toolCallArgs', id: prev.id, chunk: c.function.arguments };
              }
            }
          }
        }
      }
    }
    yield { type: 'end' };
  }

  async close(): Promise<void> {}

  // ── helpers ───────────────────────────────────────────────────────

  private headers(): Record<string, string> {
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      ...this.extraHeaders,
    };
    if (this.apiKey) h.Authorization = `Bearer ${this.apiKey}`;
    return h;
  }

  private buildBody(
      messages: Message[], tools: ToolDeclaration[], stream: boolean): any {
    const body: any = {
      model: this.model,
      messages: messages.map((m) => messageToJson(m)),
      stream,
    };
    if (this.temperature !== undefined) body.temperature = this.temperature;
    if (this.maxTokens !== undefined) body.max_tokens = this.maxTokens;
    if (tools.length) {
      body.tools = tools.map((t) => ({
        type: 'function',
        function: {
          name: t.name,
          description: t.description,
          parameters: JSON.parse(serializeSchema(t.parameters)),
        },
      }));
    }
    return body;
  }
}

/// Yield Delta events from a buffered SSE response — same shape as
/// the streaming reader path, just consumed in one shot. Used when
/// `resp.body` isn't a streaming ReadableStream (RN whatwg-fetch).
async function* parseSseChunks(
    raw: string,
    activeCalls: Map<number, { id: string; name: string }>): AsyncIterable<Delta> {
  const dbg = !!(globalThis as any).DAZZLE_DEBUG_LLM_BODY;
  let nDataLines = 0;
  let nText = 0;
  let nToolCalls = 0;
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t.startsWith('data:')) continue;
    const payload = t.slice(5).trim();
    if (!payload) continue;
    if (payload === '[DONE]') {
      if (dbg) {
        // eslint-disable-next-line no-console
        console.log('[DAZZLE_DEBUG] SSE done — dataLines=', nDataLines,
                    'text=', nText, 'toolCalls=', nToolCalls);
      }
      yield { type: 'end' } as Delta;
      return;
    }
    nDataLines++;
    let chunk: any;
    try { chunk = JSON.parse(payload); } catch (e) {
      if (dbg) {
        // eslint-disable-next-line no-console
        console.log('[DAZZLE_DEBUG] SSE parse failed for', payload.slice(0, 120));
      }
      continue;
    }
    const delta = chunk.choices?.[0]?.delta ?? {};
    if (typeof delta.content === 'string' && delta.content.length) {
      nText += delta.content.length;
      yield { type: 'text', chunk: delta.content } as Delta;
    }
    if (Array.isArray(delta.tool_calls)) {
      for (const tc of delta.tool_calls) {
        const idx = tc.index ?? 0;
        const prev = activeCalls.get(idx);
        const id   = tc.id ?? prev?.id ?? `call_${idx}`;
        const name = tc.function?.name ?? prev?.name ?? '';
        if (!prev || prev.id !== id) {
          activeCalls.set(idx, { id, name });
          nToolCalls++;
          yield { type: 'toolCallStart', id, name } as Delta;
        }
        if (tc.function?.arguments) {
          const cur = activeCalls.get(idx);
          if (cur) yield {
            type: 'toolCallArgs', id: cur.id, chunk: tc.function.arguments,
          } as Delta;
        }
      }
    }
  }
  if (dbg) {
    // eslint-disable-next-line no-console
    console.log('[DAZZLE_DEBUG] SSE end-no-DONE — dataLines=', nDataLines,
                'text=', nText, 'toolCalls=', nToolCalls);
  }
  yield { type: 'end' } as Delta;
}

/// Reassemble a non-streaming completion from a stream of SSE
/// `data: {...}` chunks. Some providers (notably HF Router → Groq)
/// always send chunked output regardless of `stream:false`. Each
/// chunk is a partial OpenAI-shaped completion in `choices[].delta`;
/// we concatenate `delta.content` and merge the last `tool_calls`.
function foldSseChunks(raw: string): any {
  const out: any = { choices: [{ delta: { content: '' } }] };
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t.startsWith('data:')) continue;
    const payload = t.slice(5).trim();
    if (!payload || payload === '[DONE]') continue;
    let chunk: any;
    try { chunk = JSON.parse(payload); } catch { continue; }
    const delta = chunk.choices?.[0]?.delta ?? {};
    if (delta.role) out.choices[0].delta.role = delta.role;
    if (typeof delta.content === 'string') {
      out.choices[0].delta.content += delta.content;
    }
    if (delta.tool_calls?.length) {
      out.choices[0].delta.tool_calls = delta.tool_calls;
    }
  }
  return out;
}

function messageToJson(m: Message): any {
  const role: Role = m.role;
  const out: any = { role, content: m.content };
  if (m.toolCalls?.length) {
    out.tool_calls = m.toolCalls.map((c) => ({
      id: c.id,
      type: 'function',
      function: { name: c.name, arguments: c.arguments },
    }));
  }
  if (m.toolCallId) out.tool_call_id = m.toolCallId;
  return out;
}
