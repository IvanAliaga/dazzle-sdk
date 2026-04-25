# chat-memory-rn — pure conversational memory on React Native

The React Native port of `samples/chat-memory`. Minimal Dazzle chat
pattern: no tools, no retrieval, no dataset — just an `LLMClient`
plus Dazzle persisting every turn as a hash so the conversation
survives app restarts and replays on cold boot.

## What the code does

```
User types → ChatAgent runs llm.stream(history + userInput)
           → `messages` Observable fires, ChatScreen re-renders
           → assistant turn committed to Dazzle as a hash
```

Dazzle storage:
- Every `ChatTurn` → `ContextStore<ChatTurn>` → hash
  `agent:<threadId>:memory:<turnId>`. Reads go through the snapshot
  cache via `HashKey.getAllDirect()` on the native side.
- The constructor iterates the store once on cold boot to restore
  prior history (ordered by the `timestamp` field).

## Run — interactive

### Prereqs
- Node 22+, `npx react-native doctor` clean.
- `samples/_scripts/link_rn.sh` has been run (publishes the Dazzle
  Android AAR locally + rsyncs the iOS Swift sources into the plugin's
  pod dir).
- `samples/chat-memory-rn/android/local.properties` contains
  `sdk.dir=<your Android SDK>`.

### Android

```bash
cd samples/chat-memory-rn
npm install
npx react-native run-android
```

### iOS

```bash
cd samples/chat-memory-rn
npm install
cd ios && pod install && cd -
npx react-native run-ios
```

## Run — automated end-to-end test

```bash
samples/_scripts/test_rn_android.sh
samples/_scripts/test_rn_ios.sh
```

Both scripts:
- `npm install` + pre-bundle JS (`react-native bundle --dev false` so
  the APK / .app runs standalone without a Metro server attached);
- build + install + launch with `DAZZLE_SAMPLE_TEST=1`;
- poll the app sandbox for the marker + JSON report;
- validate `status == "pass"` and print a one-line summary.

Last run reports land under
`samples/_scripts/_test_results/chat-memory_rn_{android,ios}.json`.

## Swap the LLM adapter

`src/llmAdapter.ts` ships with the 4-adapter pick block:

```ts
// D (default) — OpenAI-compatible HTTP (OpenAI / HF Router / Ollama / vLLM)
return new OpenAICompatibleClient({
  baseURL: 'https://api.openai.com/v1',
  model:   'gpt-4o-mini',
  apiKey:  process.env.OPENAI_API_KEY ?? '',
});

// A — llama.cpp (any GGUF)
// return await LlamaCppClient.create({ modelPath: '/data/local/tmp/qwen.gguf' });

// B — LiteRT-LM (.litertlm, Android)
// return await LiteRtLmClient.create({ modelPath: '...' });

// C — Apple Foundation Models (iOS/macOS 26+)
// if (await FoundationModelsClient.isAvailable()) {
//   return new FoundationModelsClient({ temperature: 0.3 });
// }
```

Nothing else in the sample has to change.

## Porting this to your own app

1. Copy this directory.
2. Change `threadId = 'chat-memory-default'` in `App.tsx` to whatever
   namespacing makes sense for your users (per-user, per-topic,
   per-device).
3. Edit `src/llmAdapter.ts` to pick the runtime that fits your target
   platform.
4. Optionally add tools — the `chat-iot-rn` and `chat-kb-rn` samples
   (future) will demonstrate the tool-loop wiring.
