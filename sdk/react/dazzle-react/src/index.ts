// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// dazzle-react — React (DOM) bindings for the Dazzle WebAssembly
// runtime.  Same dazzle.wasm the Flutter Web / RN Web targets ship,
// wrapped with React-friendly hooks.

// Imperative API — works without React.
export { DazzleWeb, DazzleWebHash, DazzleWebVectorIndex } from './dazzle_web';
export type { VectorSearchHit } from './dazzle_web';

// React hooks.
export {
  useDazzleInit,
  useDazzleHash,
  useVectorIndex,
  useVectorSearch,
  useAutoPersist,
} from './hooks';
