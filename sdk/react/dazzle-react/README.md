# dazzle-react

**React bindings for the Dazzle WebAssembly runtime.** HNSW vector
search + hash KV running 100% in the browser, persisted to OPFS,
exposed as React hooks.

Same `dazzle.wasm` as the `dazzle_flutter` and `dazzle-react-native`
packages — zero behaviour drift across all three web targets.

## Install

```bash
npm install dazzle-react
```

## Setup

The package ships `dazzle.wasm` (~236 KB) + `dazzle.js` (~68 KB) under
`web/native/`. Configure your bundler (Vite, Webpack, esbuild, …) to
copy them as static assets, then load them as an ES module before
your React app boots:

```html
<!-- index.html -->
<script type="module">
  import dz from "/path/to/dazzle.js";
  globalThis.dazzleModule = dz;
</script>
```

### Vite copy snippet

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

then point the loader script at `/dazzle/dazzle.js`.

## Quick start

```tsx
import {
  useDazzleInit,
  useDazzleHash,
  useVectorIndex,
  useVectorSearch,
} from 'dazzle-react';

export function App() {
  const { ready, error } = useDazzleInit();
  if (error)  return <p>Failed to load Dazzle: {error.message}</p>;
  if (!ready) return <p>Loading…</p>;

  return <Catalog />;
}

function Catalog() {
  const hash  = useDazzleHash('chat:1');
  const index = useVectorIndex('catalog');

  const handleSeed = () => {
    index.create({ dim: 1536 });
    index.add('product-1', new Float32Array(/* 1536 floats */));
    hash.set('lastSeededAt', Date.now().toString());
  };

  const { hits } = useVectorSearch('catalog', queryEmbedding, { topK: 5 });
  return (
    <ul>
      {hits.map(h => <li key={h.id}>{h.id} (d={h.distance.toFixed(3)})</li>)}
    </ul>
  );
}
```

## Imperative API

If you don't want hooks, the underlying class API works just fine:

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

## Scope (1.0.0-beta.6)

- ✅ Hash KV (HSET/HGET/HGETALL/HDEL)
- ✅ Vector index (HNSW): create / add / addBatch / search / drop
- ✅ Snapshot persistence to OPFS

Out of MVP for web (use the iOS/Android/Desktop targets):
- Lists / Sets / SortedSets / Streams standalone primitives
- On-device LLM clients (LlamaCpp, LiteRT-LM, FoundationModels)

## React Native?

If you're on React Native (with or without web target), use
[`dazzle-react-native`](../../react-native/dazzle-react-native)
instead — it ships native bindings for iOS / Android plus the same
WASM bridge for RN Web.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for per-version notes, or the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## License

Apache 2.0.
