# Changelog

All notable changes to `dazzle-react`. This package follows the
Dazzle SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.5

### Added — first public release of the React (DOM) bindings

- **`dazzle-react` npm package** — React bindings for the Dazzle
  WebAssembly runtime. HNSW vector search + hash KV running 100% in
  the browser, persisted to OPFS, exposed as idiomatic React hooks.
- Re-uses the same `dazzle.wasm` (~236 KB) the `dazzle_flutter` and
  `dazzle-react-native` packages ship — zero behavioural drift
  across all three web targets.
- **Imperative API**: `DazzleWeb`, `DazzleWebHash`,
  `DazzleWebVectorIndex` — same surface as Flutter Web's `DazzleWeb`
  for cross-platform consistency.
- **React hooks**:
  - `useDazzleInit({ opfsFileName? })` — boot the runtime once near
    the root (returns `{ ready, error }`).
  - `useDazzleHash(key)` — stable handle to a hash.
  - `useVectorIndex(name)` — stable handle to a vector index.
  - `useVectorSearch(name, query, opts?)` — re-runs search when
    query changes.
  - `useAutoPersist()` — snapshot to OPFS on unmount.

### Setup

Configure your bundler (Vite / Webpack / esbuild) to copy
`node_modules/dazzle-react/web/native/*` as static assets, then
load the module before your React app boots:

```html
<script type="module">
  import dz from "/path/to/dazzle.js";
  globalThis.dazzleModule = dz;
</script>
```

### Scope

- ✅ Hash KV + Vector index (HNSW) + OPFS snapshot persistence.
- ❌ Lists / Sets / SortedSets / Streams — use the iOS / Android /
  Desktop targets.
- ❌ On-device LLM clients — use the iOS / Android targets.

### React Native?

For React Native apps (with or without web target), use
[`dazzle-react-native`](https://www.npmjs.com/package/dazzle-react-native)
instead — it ships native bindings for iOS / Android **plus** the
same WASM bridge for RN Web.
