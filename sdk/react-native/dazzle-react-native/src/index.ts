// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Dazzle SDK for React Native — public entry point.
//
// ```ts
// import { DazzleServer } from 'dazzle-react-native';
//
// await DazzleServer.shared.start();
// const hash = DazzleServer.shared.client().hash('agent:chat:turn_1');
// await hash.set('role', 'user');
// await hash.set('text', "What's the weather in Lima?");
// const fields = await hash.getAllDirect();
// ```

// Config + server lifecycle.
export * from './config';
export { DazzleServer } from './server';

// Primitives.
export { Dazzle } from './primitives/dazzle';
export { HashKey } from './primitives/hash';
export { ListKey } from './primitives/list';
export { SetKey } from './primitives/set';
export { SortedSetKey, ScoredMember } from './primitives/sortedSet';
export { StreamKey, StreamEntry } from './primitives/stream';
export { StringKey } from './primitives/string';

// Vector index.
export {
  VectorIndex,
  VectorAlgorithm,
  VectorMetric,
  VectorSearchResult,
} from './vector/vectorIndex';

// Agent core.
export * from './agent/message';
export * from './agent/tool';
export { ContextStore } from './agent/contextStore';
export * from './agent/contextWindow';
export { LLMClient, FakeLLMClient, exitProcess } from './agent/llmClient';
export { ChatAgent, Embedder } from './agent/chatAgent';

// 5 LLM adapters.
export { OpenAICompatibleClient } from './edge/openAICompatibleClient';
export { AnthropicClient } from './edge/anthropicClient';
export { LlamaCppClient } from './edge/llamaCppClient';
export { LiteRtLmClient } from './edge/liteRtLmClient';
export { FoundationModelsClient } from './edge/foundationModelsClient';

// Command helpers (advanced users only).
export {
  dazzleCommand,
  RespValue,
  RespBulk,
  RespInt,
  RespArray,
  RespError,
  RespNull,
  DazzleTransportError,
} from './ffi/command';
