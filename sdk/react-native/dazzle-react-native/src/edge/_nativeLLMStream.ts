// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Shared plumbing for the RN-side LLM wrappers — `LlamaCppClient`,
// `FoundationModelsClient` and `AnthropicClient` all need the same
// thing: kick off a generation on the native side, listen on a
// DeviceEventEmitter event, and re-yield each frame as a `Delta`.
// Without this helper each wrapper rewrites ~50 lines of queue +
// waiter + listener-cleanup boilerplate.
//
// Bridge model that every consumer follows:
//
//   1. The native module exposes a method (e.g. `anthropicStream`)
//      that takes `{ reqId, …payload }`, returns a Promise<void>,
//      and afterwards emits a sequence of `{ reqId, type, … }`
//      events on a named EventEmitter channel until it ends.
//   2. `runNativeStream(...)` subscribes to that channel with the
//      caller-supplied `reqId`, fires the kickoff method, and
//      translates the raw event frames to `Delta` values for
//      `ChatAgent` to consume.
//   3. Frame `type` discriminator follows the same convention on
//      every native side — `text` / `toolCallStart` / `toolCallArgs`
//      / `end` / `error`. Wrappers whose backend has no concept of
//      tool-calls simply never emit those types.
//
// Note this is a *RN-only* helper; Flutter has its own bridge
// idiom (Method/EventChannel + StreamSubscription) and Kotlin/Swift
// don't need a bridge at all.

import { NativeEventEmitter, NativeModules } from 'react-native';
import { Delta } from '../agent/message';

const { DazzleReactNative } = NativeModules;

export interface NativeLLMStreamSpec {
  /**
   * EventEmitter channel the native side publishes frames on.
   * E.g. `'onLlamaToken'`, `'onAnthropicToken'`,
   * `'onFoundationToken'`.
   */
  readonly eventName: string;

  /**
   * Kick off the native generation. Implementations typically just
   * forward to a native method on `DazzleReactNative`. The argument
   * is `{ reqId, ...payload }` exactly as the wrapper composed it.
   * The promise should resolve once the call has been *accepted*;
   * the actual stream lifetime is signalled by `end` / `error`
   * events on `eventName`.
   */
  start(args: { reqId: number; [k: string]: unknown }): Promise<unknown>;
}

/**
 * Run one generation on the native side and yield each `Delta` frame
 * back to the caller. Cleans up the event listener when the iterator
 * ends (either through `end` / `error` from the native side, or when
 * the caller stops consuming).
 *
 * @throws if the native side emits a frame with `type === 'error'`.
 */
export async function* runNativeStream(
    spec: NativeLLMStreamSpec,
    payload: Record<string, unknown>): AsyncIterable<Delta> {
  const reqId = ++_reqCounter;
  const emitter = new NativeEventEmitter(DazzleReactNative);
  const queue: Delta[] = [];
  let finished = false;
  let errored: Error | null = null;
  let waiter: (() => void) | null = null;

  const sub = emitter.addListener(spec.eventName, (evt: any) => {
    if (evt?.reqId !== reqId) return;
    switch (evt?.type) {
      case 'text':
        queue.push({ type: 'text', chunk: String(evt.chunk ?? '') });
        break;
      case 'toolCallStart':
        queue.push({ type: 'toolCallStart',
                     id: String(evt.id ?? ''),
                     name: String(evt.name ?? '') });
        break;
      case 'toolCallArgs':
        queue.push({ type: 'toolCallArgs',
                     id: String(evt.id ?? ''),
                     chunk: String(evt.chunk ?? '') });
        break;
      case 'end':
        queue.push({ type: 'end' });
        finished = true;
        break;
      case 'error':
        errored = new Error(String(evt.message ?? `${spec.eventName} error`));
        queue.push({ type: 'end' });
        finished = true;
        break;
      // Unknown types are silently ignored — forward-compat for new
      // event types the native side might emit.
    }
    if (waiter) { waiter(); waiter = null; }
  });

  try {
    void spec.start({ reqId, ...payload });
    while (true) {
      while (queue.length) {
        const d = queue.shift()!;
        yield d;
        if (d.type === 'end') {
          if (errored) throw errored;
          return;
        }
      }
      if (finished) {
        if (errored) throw errored;
        return;
      }
      await new Promise<void>((res) => { waiter = res; });
    }
  } finally {
    sub.remove();
  }
}

let _reqCounter = 0;
