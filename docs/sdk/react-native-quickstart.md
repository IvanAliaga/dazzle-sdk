# React Native quickstart

Build a Dazzle-powered React Native app end-to-end. Same embedded
Valkey + HNSW vector search + ChatAgent runtime the Android / iOS
native + Flutter SDKs ship — one API across the whole stack.

Latest: **v1.0.0-beta.4**.

## What you get

Same surface as the Flutter plugin, with TypeScript types:

- `DazzleServer.shared.start()` / `.stop()` / `.waitForReady()` /
  `.client()`.
- Typed primitives: `HashKey`, `ListKey`, `SetKey`, `SortedSetKey`,
  `StreamKey`, `StringKey` with async `*Direct` methods that go through
  the native snapshot cache.
- `VectorIndex.create({algorithm, dim, metric, …})` →
  `addDirect` / `addBatchDirect` / `searchDirect`.
- `ContextStore<T>` — SCAN-based `iterate()`, hash-backed persistence.
- `ChatAgent` — three `Observable<T>` signals (`messages`,
  `streaming`, `status`) that plug into React via
  `useSyncExternalStore`.
- 5 LLM adapters: `OpenAICompatibleClient` (pure TS over `fetch` +
  line-buffered SSE; falls back to a buffered SSE parser on the RN
  whatwg-fetch polyfill), `LlamaCppClient`, `LiteRtLmClient`,
  `FoundationModelsClient`, `AnthropicClient` — the last four
  delegate to the native Dazzle SDKs via a NativeModule bridge.
  The three native-backed wrappers (LlamaCpp, FoundationModels,
  Anthropic) share a single `_nativeLLMStream` helper that owns the
  queue + waiter + listener-cleanup boilerplate, so adding the
  next provider is ~30 lines.

## Install

The package is not on npm yet. Consume it via a path dep:

```json
// package.json
"dependencies": {
  "dazzle-react-native": "file:../../sdk/react-native/dazzle-react-native"
}
```

Bootstrap the native artefacts before the first build:

```bash
samples/_scripts/link_rn.sh             # Android + iOS
samples/_scripts/link_rn.sh android     # Android only
samples/_scripts/link_rn.sh ios         # iOS only
```

Android consumes the Dazzle SDK from the same repo-local file-URL
maven repo the Flutter plugin uses (`sdk/android/build/maven-repo`).
iOS mirrors the Flutter flow: the link script rsyncs the Swift sources
+ the xcframework's `libvalkey-server.a` into
`sdk/react-native/dazzle-react-native/ios/vendored/`, and the podspec
wires `-lvalkey-server` through `user_target_xcconfig` so the host
app's final link resolves the C symbols.

## Minimum platform versions

| Platform | Target | Notes |
|----------|--------|-------|
| Android  | API 26+ | Ships `arm64-v8a` today. Each consumer app's `app/build.gradle` should set `minSdk 26` + `ndk { abiFilters "arm64-v8a" }`. |
| iOS      | 17.0+   | Bump `platform :ios, '17.0'` in your Podfile + `IPHONEOS_DEPLOYMENT_TARGET = 17.0;` in the xcodeproj. |

## Metro config — path deps + symlinks

Metro doesn't watch files outside the app root by default, and
`npm install --file:` drops a symlink into `node_modules`. Add the
plugin dir to `watchFolders` + enable symlink resolution:

```js
// metro.config.js
const path = require('path');
const { getDefaultConfig, mergeConfig } =
    require('@react-native/metro-config');

const pluginRoot = path.resolve(
    __dirname, '..', '..', 'sdk', 'react-native', 'dazzle-react-native');

module.exports = mergeConfig(getDefaultConfig(__dirname), {
  watchFolders: [pluginRoot],
  resolver: {
    extraNodeModules: new Proxy({}, {
      get: (_t, name) => path.join(__dirname, `node_modules/${String(name)}`),
    }),
    unstable_enableSymlinks: true,
  },
});
```

## Hello world

```tsx
import React, { useEffect, useState } from 'react';
import { SafeAreaView, Text } from 'react-native';
import {
  ChatAgent, DazzleServer, OpenAICompatibleClient,
} from 'dazzle-react-native';

export default function App() {
  const [agent, setAgent] = useState<ChatAgent | null>(null);

  useEffect(() => {
    (async () => {
      await DazzleServer.shared.start();
      const llm = new OpenAICompatibleClient({
        baseURL: 'https://api.openai.com/v1',
        model:   'gpt-4o-mini',
        apiKey:  process.env.OPENAI_API_KEY ?? '',
      });
      setAgent(new ChatAgent({
        threadId:     'session:42',
        llm,
        systemPrompt: 'You are a helpful on-device assistant.',
      }));
    })();
  }, []);

  return (
    <SafeAreaView style={{ flex: 1 }}>
      <Text>{agent ? 'Dazzle is up' : 'Booting…'}</Text>
    </SafeAreaView>
  );
}
```

## Anthropic (Claude) — same shape

```ts
import { AnthropicClient, ChatAgent, DazzleServer } from 'dazzle-react-native';

await DazzleServer.shared.start();

const claude = await AnthropicClient.create({
  model:     'claude-haiku-4-5-20251001',
  apiKey:    process.env.ANTHROPIC_API_KEY!,
  maxTokens: 1024,
});

const agent = new ChatAgent({
  threadId:     'session:42',
  llm:          claude,
  systemPrompt: 'You are a helpful assistant.',
});

await agent.send('Explain quantisation in one sentence.');
```

The `AnthropicClient` TS class is a thin wrapper — the actual
HTTP/SSE/JSON parsing for `/v1/messages` lives in
`AnthropicClient.kt` (Android) and `AnthropicClient.swift` (iOS),
the same files the native + Flutter SDKs use. If Anthropic
changes the API, edit two files, not four. Verified end-to-end
against `api.anthropic.com` on a Moto G35 5G — see
[`samples/PROVIDERS.md`](../../samples/PROVIDERS.md) for the
captured 4/4 live verification matrix.

## Automated sample test harness

```
samples/chat-memory-rn   zero RAG, persistent chat (shipping)
                         Android + iOS e2e reports under
                         samples/_scripts/_test_results/
samples/chat-iot-rn      (future) LLM + SortedSet tool
samples/chat-kb-rn       (future) LLM + HNSW_SQ8 vector tool
```

Android flow:

```bash
samples/_scripts/test_rn_android.sh
```

- installs the app,
- pre-bundles JS (`react-native bundle --dev false` so the APK is
  standalone, no Metro server at run-time),
- launches with `am start --es DAZZLE_SAMPLE_TEST 1` — MainActivity
  forwards the extra to `System.setProperty(...)` so the JS-side
  `isSampleTestMode()` picks it up synchronously,
- polls the app sandbox's `files/` for the JSON report.

iOS flow:

```bash
samples/_scripts/test_rn_ios.sh
```

- `pod install` (UTF-8 locale exported — Ruby 2.7 + cocoapods 1.16
  choke on ASCII-8BIT),
- `react-native bundle --dev false` + `xcodebuild Release` (iOS blocks
  JIT so debug builds can't launch standalone),
- `xcrun devicectl device install` + `process launch
  --environment-variables '{"DAZZLE_SAMPLE_TEST":"1"}'`,
- `xcrun devicectl device copy from` → reads the JSON report out of
  the app's Documents dir.

Latest PASS:

| Platform | Device          | chat-memory-rn                         |
|----------|-----------------|----------------------------------------|
| Android  | moto g35 5G     | 4 turns, 2u/2a/0t, 2 LLM calls, 53 ms  |
| iOS      | iPhone 12 Pro   | 4 turns, 2u/2a/0t, 2 LLM calls,  1 ms  |

## Performance caveat (and how to lift it)

React Native's bridge is asynchronous JSON-over-serialisation. Every
`dazzleCommand(argv)` call crosses the bridge, so the hot path is
~100 µs slower per call than Flutter's `dart:ffi` path. In practice
that is still 10×–50× faster than a TCP loopback to a local Redis /
Valkey, and entirely acceptable for the ChatAgent workloads the
samples exercise.

For perf-sensitive users we recommend either:

1. Drop to the native Kotlin / Swift SDK for the specific hot loop
   (same binary, same API).
2. Upgrade this plugin to JSI + TurboModule — same codebase, just a
   different bridge. Tracked in docs/ROADMAP.md.

## Reporting an issue

GitHub: https://github.com/IvanAliaga/dazzle/issues — include the
output of `npx react-native doctor` + the JSON report from
`samples/_scripts/_test_results/chat-*_rn_*.json` if the automated
harness ran.
