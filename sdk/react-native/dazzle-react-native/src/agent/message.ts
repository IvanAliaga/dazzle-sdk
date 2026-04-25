// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

export type Role = 'system' | 'user' | 'assistant' | 'tool';

export interface ToolCall {
  readonly id: string;
  readonly name: string;
  readonly arguments: string;   // raw JSON
}

export interface Message {
  readonly role: Role;
  readonly content: string;
  readonly toolCalls?: ToolCall[];
  readonly toolCallId?: string;
}

export interface ChatTurn {
  readonly id: string;
  readonly role: Role;
  readonly text: string;
  readonly toolCalls?: ToolCall[];
  readonly toolCallId?: string;
  readonly timestamp: number;
}

export function turnToMessage(t: ChatTurn): Message {
  return {
    role: t.role,
    content: t.text,
    toolCalls: t.toolCalls,
    toolCallId: t.toolCallId,
  };
}

// Streaming deltas emitted by LLMClient.stream.
export type Delta =
  | { type: 'text'; chunk: string }
  | { type: 'toolCallStart'; id: string; name: string }
  | { type: 'toolCallArgs'; id: string; chunk: string }
  | { type: 'end' };

// Blocking completion shape.
export type Completion =
  | { type: 'text'; message: Message }
  | { type: 'toolCalls'; message: Message };

export type AgentStatus =
  | 'idle' | 'thinking' | 'streaming' | 'toolCalling' | 'error';

export interface StreamingMessage {
  readonly text: string;
  readonly activeTool: string | null;
}
