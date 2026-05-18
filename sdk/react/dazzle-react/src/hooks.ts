// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// React hooks over the DazzleWeb runtime.  These are convenience
// wrappers — the underlying API is `DazzleWeb` from ./dazzle_web,
// which works fine without React if you prefer imperative control.

import { useEffect, useState, useMemo, useCallback } from 'react';

import { DazzleWeb, DazzleWebHash, DazzleWebVectorIndex, VectorSearchHit } from './dazzle_web';

/**
 * Initialise the WASM module + restore an OPFS snapshot, exactly once.
 *
 * Returns:
 *   - `ready`  — true once initialise() resolved
 *   - `error`  — the Error if loading failed (e.g. missing <script> tag)
 *
 * Use this once near the root of your tree:
 *
 * ```tsx
 * const { ready, error } = useDazzleInit();
 * if (error) return <ErrorScreen error={error} />;
 * if (!ready) return <Spinner />;
 * return <App />;   // children can use useDazzleHash / useVectorIndex
 * ```
 */
export function useDazzleInit(opts: { opfsFileName?: string } = {}): { ready: boolean; error: Error | null } {
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    let cancelled = false;
    DazzleWeb.initialize(opts).then(
      () => { if (!cancelled) setReady(true); },
      (e: unknown) => { if (!cancelled) setError(e instanceof Error ? e : new Error(String(e))); },
    );
    return () => { cancelled = true; };
    // We deliberately don't depend on opts.opfsFileName — switching it
    // post-mount would mean re-initialising the singleton, which is a
    // power-user operation; call DazzleWeb.debugReset() + remount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { ready, error };
}

/**
 * Returns a stable handle to the hash at `key`.  The handle methods
 * (set / get / etc.) are synchronous because the WASM call is
 * in-process — no need for useEffect / loading states.
 *
 * If `useDazzleInit` hasn't resolved yet, calling any handle method
 * will throw.  Render-gate behind `ready`.
 */
export function useDazzleHash(key: string): DazzleWebHash {
  return useMemo(() => DazzleWeb.hash(key), [key]);
}

/**
 * Returns a stable handle to the vector index at `name`.
 */
export function useVectorIndex(name: string): DazzleWebVectorIndex {
  return useMemo(() => DazzleWeb.vectorIndex(name), [name]);
}

/**
 * Run a vector search and re-render when the query changes.
 *
 * `query` is treated by reference identity — wrap it in `useMemo` if
 * you compute it from props/state, otherwise the search runs every
 * render.
 */
export function useVectorSearch(
  indexName: string,
  query: Float32Array | null,
  opts: { topK?: number; ef?: number } = {},
): { hits: VectorSearchHit[]; refresh: () => void } {
  const idx = useVectorIndex(indexName);
  const [hits, setHits] = useState<VectorSearchHit[]>([]);

  const refresh = useCallback(() => {
    if (!query) { setHits([]); return; }
    setHits(idx.search(query, opts));
  }, [idx, query, opts.topK, opts.ef]);  // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    refresh();
  }, [refresh]);

  return { hits, refresh };
}

/**
 * Auto-persist on unmount.  Drops the snapshot to OPFS when the
 * component using this hook unmounts (e.g. on app navigation away).
 * Useful as a fire-and-forget call site near the app root.
 */
export function useAutoPersist(): void {
  useEffect(() => {
    return () => {
      // Fire-and-forget — DazzleWeb.persist resolves asynchronously
      // but the React unmount path doesn't wait for it.
      void DazzleWeb.persist();
    };
  }, []);
}
