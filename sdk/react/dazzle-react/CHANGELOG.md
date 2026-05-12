# Changelog

All notable changes to `dazzle-react`. This package follows the
Dazzle SDK release line; see the
[repo CHANGELOG](https://github.com/IvanAliaga/dazzle-sdk/blob/main/CHANGELOG.md)
for cross-stack release notes.

## 1.0.0-beta.6 — 2026-05-12

### Paper-side updates (applies to every binding — the SDK runs the same harness everywhere)

- **§5.9.5 cross-platform extension.** End-to-end RAG reproduction
  now spans **5 physical mobile SoCs across 2 operating systems**:
  Unisoc T760 / Cortex-A76 (Moto G35 5G, Android 14), QCOM SD662 /
  Cortex-A73 (Moto G30, Android 11), HiSilicon Kirin 659 / Cortex-A53
  (Huawei P20 Lite, Android 9 / EMUI 9), MediaTek Helio G80 /
  Cortex-A75 (Huawei Y9a / FRL-L23, Android 10 / EMUI 10), and Apple
  A14 / Firestorm (iPhone 12 Pro, iOS 26). Four Android microarchitecture
  generations plus Apple Firestorm. Bootstrap CIs (B=10000, paired-qid
  resampling) star-mark every F1_short ratio at 95% confidence across
  the spread.
- **§5.9.6 quantization sensitivity sweep.** Q4_K_M vs Q5_K_M on the
  two v8.2 HNSW chips (Moto G35 5G + Huawei Y9a). Headline: the
  `em_contains` metric is flat between quant levels (deltas ≤ 0.025
  on every cell, inside the per-cell CI half-width). Latency reveals
  a bandwidth-vs-compute split — the faster A76 chip pays a +50%
  wall-clock tax for Q5, the slower A75 chip pays ≤+13% because it
  was already bandwidth-bound on Q4 weights. Disk footprint cost is
  +6.3% on the 0.5B GGUF and +15% on the 1.5B GGUF.
- **REPRODUCIBILITY §4a + §4b.** New recipes: per-device chunked
  instrumentation for §5.9.5 (any new chip can be added with a small
  set of `am instrument` invocations) and GGUF-swap for §5.9.6 (no
  rebuild needed to A/B Q4 vs Q5 vs future quant variants).
- **PDFs regenerated.** `research/paper/arxiv-build/paper.pdf` and
  `paper_es.pdf` rebuilt from the updated paper sources.

### No React-side surface changes

- This beta.6 cycle was paper-side + Android/iOS native fixes;
  the React (DOM) WebAssembly surface is unchanged.

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
