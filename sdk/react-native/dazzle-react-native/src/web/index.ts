// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Dazzle SDK for React Native — Web target (Scope A).
//
// Importing this sub-module pulls in the WASM-backed runtime that runs
// HNSW vector search + a hash KV in-process inside the browser, with
// persistence backed by the Origin Private File System (OPFS).
//
// Setup contract (web/index.html or your bundler's entry HTML):
//
//     <script type="module">
//       import dz from "/path/to/dazzle.js";
//       globalThis.dazzleModule = dz;
//     </script>
//
// Then in JS / TS:
//
//     import { DazzleWeb } from 'dazzle-react-native/web';
//
//     await DazzleWeb.initialize();
//     const hash = DazzleWeb.hash('chat:1');
//     hash.set('role', 'user');
//     hash.set('text', 'hello');
//
//     const vec = DazzleWeb.vectorIndex('catalog');
//     vec.create({ dim: 1536 });
//     vec.add('product-1', new Float32Array(1536));
//     const hits = vec.search(query, { topK: 5 });
//
//     await DazzleWeb.persist();   // snapshot → OPFS

export { DazzleWeb, DazzleWebHash, DazzleWebVectorIndex } from './dazzle_web';
export type { VectorSearchHit } from './dazzle_web';
