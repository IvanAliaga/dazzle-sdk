# dazzle-react-native

React Native package for [Dazzle](https://github.com/IvanAliaga/dazzle-sdk)
— the embedded, in-process database for on-device LLM agents. Same
embedded Valkey + HNSW vector search + ChatAgent runtime the
Android / iOS native + Flutter SDKs ship.

Latest: **v1.0.0-beta.4** — see
[../../../CHANGELOG.md](../../../CHANGELOG.md).

## Install

```bash
npm install dazzle-react-native
# or: yarn add dazzle-react-native
```

iOS pods (run after install):

```bash
cd ios && pod install && cd ..
```

That's it for app developers — the published tarball already bundles
the iOS Swift sources + `libvalkey-server.a` so CocoaPods can compile
them in. On Android the AAR resolves through the package's own
`android/build.gradle` (no extra wiring needed).

### Local development (SDK contributors only)

If you're hacking on Dazzle itself and want a sample app to consume
the working tree, swap the npm install for a path dep:

```json
// package.json of your RN app
"dependencies": {
  "dazzle-react-native": "file:../../sdk/react-native/dazzle-react-native"
}
```

Then bootstrap the native artefacts:

```bash
samples/_scripts/link_rn.sh             # Android + iOS
samples/_scripts/link_rn.sh android     # Android only
samples/_scripts/link_rn.sh ios         # iOS only
```

This publishes the Android AAR into a repo-local file-URL Maven repo
(`sdk/android/build/maven-repo`) and rsyncs the iOS Swift sources +
`libvalkey-server.a` into
`sdk/react-native/dazzle-react-native/ios/vendored/`.

## Minimum target

| Setting               | Value                          |
|-----------------------|--------------------------------|
| React Native          | 0.85+                          |
| Android `minSdk`      | 26 (`arm64-v8a` only today)    |
| iOS deployment target | 17.0                           |
| TypeScript            | 5.x                            |

Add `metro.config.js` watch folders if your sample lives outside the
plugin tree — see
[`docs/sdk/react-native-quickstart.md`](../../../docs/sdk/react-native-quickstart.md)
for the full Metro snippet.

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

## LLM adapters

Five adapters ship — every one emits the same `Delta` stream
(`text` / `toolCallStart` / `toolCallArgs` / `end`) so the
surrounding `ChatAgent` / `Tool` loop is identical when you swap
them.

| Adapter                  | Where it runs                                      | Notes                                                                                  |
|--------------------------|----------------------------------------------------|----------------------------------------------------------------------------------------|
| `LlamaCppClient`         | Native (delegates to the Kotlin / Swift SDK)       | GGUF model on-device. Same llama.cpp every other Dazzle SDK uses.                      |
| `LiteRtLmClient`         | Native (Android opt-in; iOS via our port)          | LiteRT-LM `.litertlm` runtime. Opt-in on RN today (Kotlin 2.1 vs 2.3 metadata gap).    |
| `FoundationModelsClient` | Native (iOS 26+ / macOS 26+)                       | Apple Intelligence 3 B on-device.                                                      |
| `OpenAICompatibleClient` | Pure TypeScript (`fetch` + line-buffered SSE)      | OpenAI / HF Router / Ollama / vLLM / Groq / Together / any proxy. Falls back to a buffered SSE parser when `resp.body === null` (RN whatwg-fetch).|
| `AnthropicClient`        | Native (delegates to the Kotlin / Swift SDK)       | Anthropic `/v1/messages` API (Claude Haiku / Sonnet / Opus).                           |

The four native-backed wrappers (LlamaCpp, LiteRT, FoundationModels,
Anthropic) share a single `_nativeLLMStream` helper that owns the
`DeviceEventEmitter` queue + waiter + listener cleanup. Adding the
next native-backed provider takes ~30 lines instead of ~150.

### Anthropic example

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

The `AnthropicClient` TS class is a thin wrapper over the native
`AnthropicClient.kt` / `AnthropicClient.swift` — the actual
HTTP/SSE/JSON parsing for `/v1/messages` lives in **two files**, not
four. Verified end-to-end against `api.anthropic.com` on a Moto
G35 5G — see
[`samples/PROVIDERS.md`](../../../samples/PROVIDERS.md) for the
captured 4/4 live verification matrix.

## Performance — what to expect

The hot path goes through a JSI sync-bridge (`dazzleCommandSync` /
`snapHGetAllSync` / `snapZRangeByScoreSync` / `snapSMembersSync` /
`snapGetSync`) on both Android (Kotlin) and iOS (ObjC++ / Swift).
**5–10× faster than the async bridge** (~15 µs vs ~100 µs per call)
on Moto G35 5G + iPhone 12 Pro.

If a sync method isn't available at runtime the TS wrappers fall
back to the async path automatically, so the same code runs on older
React Native versions.

## React Native Web (1.0.0-beta.5+)

For RN apps that target web (Expo Web, react-native-web), Dazzle ships a
WebAssembly runtime that runs HNSW vector search and a hash KV
**in-process inside the browser**, with persistence backed by the Origin
Private File System (OPFS). No remote server, no proxy — same offline
promise the iOS / Android targets deliver, on the web.

**Scope** (this beta): Hash KV + Vector index + OPFS snapshot.
**Not yet on web**: List / Set / SortedSet / Stream standalone primitives,
on-device LLM clients — those stay on iOS / Android.

### Setup

1. The package ships `web/native/dazzle.wasm` (~236 KB) +
   `web/native/dazzle.js` (~68 KB). Configure your bundler to serve them
   as static assets (Webpack: `copy-webpack-plugin`; Metro web: place
   under `public/`).

2. Add the loader script to your bundler's HTML entry, **before** your
   app bundle loads:

   ```html
   <script type="module">
     import dz from "/path/to/dazzle.js";
     globalThis.dazzleModule = dz;
   </script>
   ```

3. In your TypeScript / JavaScript:

   ```ts
   import { DazzleWeb } from 'dazzle-react-native/web';

   await DazzleWeb.initialize();          // loads WASM + restores OPFS
   const hash = DazzleWeb.hash('chat:1');
   hash.set('role', 'user');
   hash.set('text', 'hello');

   const vec = DazzleWeb.vectorIndex('catalog');
   vec.create({ dim: 1536 });
   vec.add('product-1', new Float32Array(1536));
   const hits = vec.search(query, { topK: 5 });

   await DazzleWeb.persist();             // snapshot → OPFS
   ```

The `dazzle-react-native/web` sub-path is a separate entry point — your
mobile bundles never load the WASM glue, so iOS / Android binary size is
unchanged.

## Documentation

- Quickstart: [`docs/sdk/react-native-quickstart.md`](../../../docs/sdk/react-native-quickstart.md)
- API contract: [`docs/sdk/API_CONTRACT.md`](../../../docs/sdk/API_CONTRACT.md)
- LLM provider matrix + live verification: [`samples/PROVIDERS.md`](../../../samples/PROVIDERS.md)
- Roadmap: [`docs/ROADMAP.md`](../../../docs/ROADMAP.md)

## Samples

Three RN samples under [`samples/chat-*-rn/`](../../../samples/):

- [`samples/chat-memory-rn`](../../../samples/chat-memory-rn) — pure
  conversational history
- [`samples/chat-iot-rn`](../../../samples/chat-iot-rn) —
  tool-calling + SortedSet retrieval
- [`samples/chat-kb-rn`](../../../samples/chat-kb-rn) — vector
  search (HNSW_SQ8) RAG

Each has a headless test mode driven by an intent extra
(`am start --es DAZZLE_SAMPLE_TEST 1` on Android, env on iOS) that
runs the full `ChatAgent` + tool loop with `FakeLLMClient`, writes
a JSON report, and exits. See
`samples/_scripts/test_rn_{android,ios}.sh`.

## License

Apache 2.0 — see [LICENSE](../../../LICENSE). Valkey portions remain
under BSD-3-Clause; see [ATTRIBUTION.md](../../../ATTRIBUTION.md).
