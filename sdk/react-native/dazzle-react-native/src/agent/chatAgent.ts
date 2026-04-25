// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Observable ChatAgent — mirrors the native implementations. Three
// observable signals (`messages`, `streaming`, `status`) expose state
// via a simple listener pattern (React consumers can wrap with
// `useSyncExternalStore`).

import {
  AgentStatus, ChatTurn, Delta, Message, Role, StreamingMessage,
  ToolCall, turnToMessage,
} from './message';
import { LLMClient } from './llmClient';
import { ContextStore } from './contextStore';
import { ContextWindow, CompactionPolicy, defaultCompaction } from './contextWindow';
import {
  Tool, ToolContext, ToolDeclaration, invokeToolRaw, toolToDeclaration,
} from './tool';
import { VectorIndex } from '../vector/vectorIndex';

/** Embed a string into a fixed-dim vector. Same shape Kotlin / Swift
 *  / Flutter SDKs expose; consumers plug their own embedder
 *  (BGE-small via llama.cpp --embedding, OpenAI's /embeddings API,
 *  a hash-bucket toy for demos, …). */
export type Embedder = (text: string) => Promise<number[]>;

export interface ChatAgentOptions {
  threadId: string;
  llm: LLMClient;
  tools?: Tool[];
  systemPrompt?: string;
  contextWindow?: ContextWindow;
  compaction?: CompactionPolicy;
  maxToolIterations?: number;
  /** Required only when `contextWindow.kind === 'vectorRecall'`. */
  embedder?: Embedder;
  embeddingDim?: number;
}

type Listener<T> = (value: T) => void;

class Observable<T> {
  private listeners = new Set<Listener<T>>();
  constructor(public value: T) {}
  set(v: T) { this.value = v; for (const l of this.listeners) l(v); }
  subscribe(l: Listener<T>): () => void {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  }
}

export class ChatAgent {
  readonly messages  = new Observable<ChatTurn[]>([]);
  readonly streaming = new Observable<StreamingMessage | null>(null);
  readonly status    = new Observable<AgentStatus>('idle');

  private readonly threadId: string;
  private readonly llm: LLMClient;
  private readonly tools: Tool[];
  private readonly systemPrompt: string;
  private readonly contextWindow: ContextWindow;
  private readonly compaction: CompactionPolicy;
  private readonly maxToolIterations: number;
  private readonly memory: ContextStore<ChatTurn>;
  private readonly embedder: Embedder | undefined;
  private readonly embeddingDim: number | undefined;
  private vectorIndex: VectorIndex | null = null;
  private currentAbort: AbortController | null = null;

  constructor(opts: ChatAgentOptions) {
    this.threadId = opts.threadId;
    this.llm = opts.llm;
    this.tools = opts.tools ?? [];
    this.systemPrompt = opts.systemPrompt ?? 'You are a helpful assistant.';
    this.contextWindow = opts.contextWindow ?? { kind: 'lastN', n: 40 };
    this.compaction = opts.compaction ?? defaultCompaction;
    this.maxToolIterations = opts.maxToolIterations ?? 8;
    this.embedder = opts.embedder;
    this.embeddingDim = opts.embeddingDim;
    this.memory = makeChatTurnStore(this.threadId);
    void this.restore();
    void this.initVectorIndex();
  }

  private async initVectorIndex(): Promise<void> {
    if (this.contextWindow.kind !== 'vectorRecall') return;
    if (!this.embedder || !this.embeddingDim || this.embeddingDim <= 0) return;
    try {
      this.vectorIndex = await VectorIndex.create({
        name:        `agent:${this.threadId}:idx`,
        hashPrefix:  `agent:${this.threadId}:memory`,
        vectorField: 'emb',
        dim:         this.embeddingDim,
        algorithm:   'hnswSq8',
        metric:      'cosine',
      });
    } catch {
      // Best-effort. If the vector index can't be created we fall
      // back to LastN implicitly (see `assembleHistory`).
    }
  }

  private async restore(): Promise<void> {
    const restored: ChatTurn[] = [];
    for await (const [, turn] of this.memory.iterate()) restored.push(turn);
    restored.sort((a, b) => a.timestamp - b.timestamp);
    this.messages.set(restored);
  }

  /** Kick off a user turn. */
  async send(userInput: string): Promise<void> {
    if (this.status.value !== 'idle') return;
    this.status.set('thinking');
    // Local flag instead of re-reading `this.status.value` in `finally` — TS
    // narrows the value to the literal `'idle'` from the guard above and
    // can't see the in-place `.set('thinking')` mutation, so `!== 'error'`
    // would be flagged as `TS2367 This comparison appears to be
    // unintentional because the types '"idle"' and '"error"' have no
    // overlap`. The flag captures the same intent without fighting the
    // narrowing.
    let errored = false;
    try {
      await this.runTurn(userInput);
    } catch (e) {
      errored = true;
      this.status.set('error');
      throw e;
    } finally {
      this.streaming.set(null);
      if (!errored) this.status.set('idle');
    }
  }

  cancel(): void {
    this.currentAbort?.abort();
    this.streaming.set(null);
    this.status.set('idle');
  }

  async close(): Promise<void> {
    this.currentAbort?.abort();
    await this.llm.close();
  }

  // ── Turn loop ─────────────────────────────────────────────────────

  private async runTurn(userInput: string): Promise<void> {
    const userTurn: ChatTurn = {
      id: newId(), role: 'user', text: userInput,
      timestamp: Date.now(),
    };
    await this.memory.put(userTurn.id, userTurn);
    await this.indexTurn(userTurn);
    this.messages.set([...this.messages.value, userTurn]);

    let iteration = 0;
    while (iteration < this.maxToolIterations) {
      iteration++;
      const history = await this.assembleHistory(userInput);
      const prompt: Message[] = [
        { role: 'system', content: this.systemPrompt },
        ...history.map(turnToMessage),
      ];
      const toolDecls = this.tools.map(toolToDeclaration);

      this.status.set('streaming');
      this.streaming.set({ text: '', activeTool: null });

      const collected = await this.collectStream(prompt, toolDecls);

      if (collected.toolCalls.length > 0) {
        const assistantTurn: ChatTurn = {
          id: newId(), role: 'assistant', text: collected.text,
          toolCalls: collected.toolCalls,
          timestamp: Date.now(),
        };
        await this.memory.put(assistantTurn.id, assistantTurn);
        await this.indexTurn(assistantTurn);
        this.messages.set([...this.messages.value, assistantTurn]);

        this.status.set('toolCalling');
        for (const call of collected.toolCalls) {
          const response = await this.runToolCall(call);
          const toolTurn: ChatTurn = {
            id: newId(), role: 'tool', text: response,
            toolCallId: call.id, timestamp: Date.now(),
          };
          await this.memory.put(toolTurn.id, toolTurn);
          await this.indexTurn(toolTurn);
          this.messages.set([...this.messages.value, toolTurn]);
        }
        this.status.set('thinking');
      } else {
        const finalTurn: ChatTurn = {
          id: newId(), role: 'assistant', text: collected.text,
          timestamp: Date.now(),
        };
        await this.memory.put(finalTurn.id, finalTurn);
        await this.indexTurn(finalTurn);
        this.messages.set([...this.messages.value, finalTurn]);
        break;
      }
    }

    await this.runCompaction();
  }

  private async collectStream(
      messages: Message[],
      tools: ToolDeclaration[]): Promise<{ text: string; toolCalls: ToolCall[] }> {
    let text = '';
    const builders = new Map<string, { name: string; args: string }>();
    const callOrder: string[] = [];

    for await (const delta of this.llm.stream({ messages, tools })) {
      this.dispatchDelta(delta, (d) => {
        switch (d.type) {
          case 'text':
            text += d.chunk;
            this.streaming.set({
              text,
              activeTool: this.streaming.value?.activeTool ?? null,
            });
            break;
          case 'toolCallStart':
            builders.set(d.id, { name: d.name, args: '' });
            callOrder.push(d.id);
            this.streaming.set({ text, activeTool: d.name });
            break;
          case 'toolCallArgs': {
            const prev = builders.get(d.id);
            if (prev) prev.args += d.chunk;
            break;
          }
          case 'end':
            break;
        }
      });
    }

    const toolCalls: ToolCall[] = [];
    for (const id of callOrder) {
      const b = builders.get(id);
      if (b) toolCalls.push({ id, name: b.name, arguments: b.args });
    }
    return { text, toolCalls };
  }

  private dispatchDelta(delta: Delta, apply: (d: Delta) => void): void {
    apply(delta);
  }

  private async runToolCall(call: ToolCall): Promise<string> {
    const tool = this.tools.find((t) => t.name === call.name);
    if (!tool) {
      return JSON.stringify({
        error: 'UnknownTool',
        message: `Tool '${call.name}' not registered`,
      });
    }
    try {
      const ctx: ToolContext = { stores: {} };
      return await invokeToolRaw(tool, call.arguments, ctx);
    } catch (e: any) {
      return JSON.stringify({
        error: e?.name ?? 'Error',
        message: e?.message ?? String(e),
      });
    }
  }

  private async assembleHistory(userInput: string): Promise<ChatTurn[]> {
    const all = this.messages.value;
    switch (this.contextWindow.kind) {
      case 'lastN':
        return all.length <= this.contextWindow.n
            ? all
            : all.slice(all.length - this.contextWindow.n);
      case 'all':
        return all;
      case 'vectorRecall': {
        const keepRecent = this.contextWindow.keepRecent;
        const k = this.contextWindow.k;
        const recent = all.length <= keepRecent
            ? all
            : all.slice(all.length - keepRecent);
        if (!this.vectorIndex || !this.embedder || k <= 0 ||
            all.length <= keepRecent) {
          return recent;
        }
        const recentIds = new Set(recent.map((t) => t.id));
        try {
          const vec = await this.embedder(userInput);
          const hits = await this.vectorIndex.searchDirect(
              vec, k + keepRecent);
          const byId = new Map(all.map((t) => [t.id, t] as const));
          const recalled: ChatTurn[] = [];
          for (const h of hits) {
            const idx = h.id.lastIndexOf(':');
            const turnId = idx >= 0 ? h.id.substring(idx + 1) : h.id;
            if (recentIds.has(turnId)) continue;
            const turn = byId.get(turnId);
            if (turn) {
              recalled.push(turn);
              if (recalled.length >= k) break;
            }
          }
          recalled.sort((a, b) => a.timestamp - b.timestamp);
          return [...recalled, ...recent];
        } catch {
          return recent;
        }
      }
    }
  }

  private async indexTurn(turn: ChatTurn): Promise<void> {
    if (!this.vectorIndex || !this.embedder || !turn.text) return;
    try {
      const vec = await this.embedder(turn.text);
      await this.vectorIndex.addDirect(
          `agent:${this.threadId}:memory:${turn.id}`, vec);
    } catch {
      // best effort
    }
  }

  private async runCompaction(): Promise<void> {
    if (this.compaction.kind === 'none') return;
    const max = this.compaction.maxTurns;
    if (this.messages.value.length <= max) return;
    const drop = this.messages.value.length - max;
    const toDrop = this.messages.value.slice(0, drop);
    for (const t of toDrop) await this.memory.delete(t.id);
    this.messages.set(this.messages.value.slice(drop));
  }
}

function newId(): string {
  _counter = (_counter + 1) % 1_000_000_000;
  return `${Date.now()}-${_counter}`;
}
let _counter = 0;

function makeChatTurnStore(threadId: string): ContextStore<ChatTurn> {
  return new ContextStore<ChatTurn>({
    name: `agent:${threadId}:memory`,
    encode: (t) => {
      const out: Record<string, string> = {
        id: t.id, role: t.role, text: t.text, ts: String(t.timestamp),
      };
      if (t.toolCallId) out.toolCallId = t.toolCallId;
      if (t.toolCalls?.length) out.toolCalls = encodeToolCalls(t.toolCalls);
      return out;
    },
    decode: (f) => {
      const roleName = f.role as Role | undefined;
      const text = f.text;
      const ts = parseInt(f.ts ?? '', 10);
      const id = f.__id ?? f.id;
      if (!roleName || text === undefined || !Number.isFinite(ts) || !id) {
        return null;
      }
      return {
        id, role: roleName, text,
        toolCallId: f.toolCallId,
        toolCalls: f.toolCalls ? decodeToolCalls(f.toolCalls) : undefined,
        timestamp: ts,
      };
    },
  });
}

function encodeToolCalls(calls: readonly ToolCall[]): string {
  const parts = calls.map((c) =>
      [c.id, c.name, c.arguments.replace(/\|/g, '\\|')].join('~'));
  return `[${parts.join('|')}]`;
}

function decodeToolCalls(raw: string): ToolCall[] {
  if (raw.length < 2 || raw[0] !== '[' || raw[raw.length - 1] !== ']') return [];
  const body = raw.substring(1, raw.length - 1);
  if (!body) return [];
  return body.split('|').flatMap((chunk) => {
    const parts = chunk.split('~');
    if (parts.length < 3) return [];
    return [{
      id: parts[0],
      name: parts[1],
      arguments: parts.slice(2).join('~').replace(/\\\|/g, '|'),
    }];
  });
}
