# React (DOM) quickstart

`dazzle-react` ships first-class React bindings for the Dazzle
WebAssembly runtime. HNSW vector search + hash KV running 100% in the
browser, persisted to OPFS, exposed as idiomatic React hooks
(`useDazzleHash`, `useVectorIndex`, `useVectorSearch`).

Same `dazzle.wasm` (236 KB) the `dazzle_flutter` and
`dazzle-react-native` packages use — zero behavioural drift across
all three web targets.

Latest: **v1.0.0-beta.5**.

## Install

```bash
npm install dazzle-react
```

## Setup — 3 steps

**1. Configure your bundler to copy the WASM assets** as static files.

Vite:
```ts
// vite.config.ts
import { viteStaticCopy } from 'vite-plugin-static-copy';

export default {
  plugins: [
    viteStaticCopy({
      targets: [{ src: 'node_modules/dazzle-react/web/native/*', dest: 'dazzle' }],
    }),
  ],
};
```

Webpack:
```js
// webpack.config.js — uses copy-webpack-plugin
new CopyPlugin({
  patterns: [{ from: 'node_modules/dazzle-react/web/native', to: 'dazzle' }],
}),
```

**2. Add the loader script to `index.html`** before your app bundle:

```html
<script type="module">
  import dz from "/dazzle/dazzle.js";
  globalThis.dazzleModule = dz;
</script>
```

**3. Render with the hooks:**

```tsx
import { useDazzleInit, useDazzleHash, useVectorSearch } from 'dazzle-react';

export function App() {
  const { ready, error } = useDazzleInit();
  if (error)  return <p>Failed: {error.message}</p>;
  if (!ready) return <p>Loading…</p>;
  return <Catalog />;
}

function Catalog({ query }: { query: Float32Array }) {
  const { hits } = useVectorSearch('catalog', query, { topK: 5 });
  return (
    <ul>
      {hits.map(h => <li key={h.id}>{h.id} (d={h.distance.toFixed(3)})</li>)}
    </ul>
  );
}
```

## Imperative API

If you don't want hooks, the underlying class API works just fine
(same surface as the Flutter Web `DazzleWeb`):

```ts
import { DazzleWeb } from 'dazzle-react';

await DazzleWeb.initialize();
DazzleWeb.hash('chat:1').set('role', 'user');
const hits = DazzleWeb.vectorIndex('catalog').search(query, { topK: 5 });
await DazzleWeb.persist();
```

## Hooks

| Hook | Returns | Use |
|---|---|---|
| `useDazzleInit({ opfsFileName? })` | `{ ready, error }` | Boot the runtime once near the root |
| `useDazzleHash(key)` | `DazzleWebHash` | Stable handle to a hash |
| `useVectorIndex(name)` | `DazzleWebVectorIndex` | Stable handle to a vector index |
| `useVectorSearch(name, query, opts?)` | `{ hits, refresh }` | Re-runs search when query changes |
| `useAutoPersist()` | `void` | Snapshot to OPFS on unmount |

## Scope

- ✅ Hash KV (HSET/HGET/HGETALL/HDEL)
- ✅ Vector index (HNSW): create / add / addBatch / search / drop
- ✅ Snapshot persistence to OPFS

Out of MVP for web (use the iOS / Android / .NET / Desktop targets):
- Lists / Sets / SortedSets / Streams standalone primitives
- On-device LLM clients (LlamaCpp, LiteRT-LM, FoundationModels)

## React Native?

Use [`dazzle-react-native`](./react-native-quickstart.md) — it ships
native iOS / Android bindings *plus* the same web bridge for React
Native Web.

## Reporting an issue

[https://github.com/IvanAliaga/dazzle-sdk/issues](https://github.com/IvanAliaga/dazzle-sdk/issues)
