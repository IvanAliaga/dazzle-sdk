/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 * SPDX-License-Identifier: Apache-2.0
 *
 * dazzle_lite.h — public C API for the lightweight, in-process Dazzle
 * runtime that ships in:
 *
 *   - Flutter Web / RN Web         via WebAssembly (core/web/ build)
 *   - Flutter Desktop (Linux/macOS/Windows) via dart:ffi
 *   - Linux / macOS / Windows C++ server apps via -ldazzle_lite
 *
 * This is intentionally a SUBSET of the full Dazzle/Valkey surface —
 * it covers Hash KV + HNSW vector search + binary snapshot, and skips
 * Lists / Sets / SortedSets / Streams / RESP / TCP / cluster.  The
 * subset is enough to build RAG and chat-memory apps end-to-end;
 * apps that need the full surface link the iOS XCFramework / Android
 * AAR / .NET Dazzle.NET package which embed Valkey 9.0.3.
 *
 * Same single-translation-unit source (core/web/src/dazzle_wasm.cpp)
 * compiles to both the WebAssembly module and the native shared
 * library — there is no behavioural drift between web and desktop.
 *
 * Threading: single-threaded.  Callers wrap concurrent access at a
 * higher layer.  The WASM runtime is single-threaded by default in
 * the browser; the native build assumes the same discipline.
 */

#ifndef DAZZLE_LITE_H
#define DAZZLE_LITE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- */
/* Hash KV                                                           */
/* ---------------------------------------------------------------- */

/* Returns 1 on success, -1 on null inputs. */
int dazzle_hset(const char *key, const char *field, const char *value);

/* Returns the stored value as a NUL-terminated string owned by the
 * library, valid only until the next dazzle_* call.  NULL if the
 * key/field doesn't exist. */
const char *dazzle_hget(const char *key, const char *field);

/* Returns 1 if a field was deleted, 0 otherwise. */
int dazzle_hdel(const char *key, const char *field);

/* Returns 1 if the field exists, 0 otherwise. */
int dazzle_hexists(const char *key, const char *field);

/* Returns a NUL-separated record stream:
 *   "field1\0value1\0field2\0value2\0"
 * Owned by the library; valid only until the next dazzle_* call.
 * Returns "" (empty string) when the key has no fields. */
const char *dazzle_hgetall(const char *key);

/* Drop the entire hash.  Returns 1 if it existed. */
int dazzle_del(const char *key);

/* ---------------------------------------------------------------- */
/* Vector index — HNSW with L2 distance                              */
/* ---------------------------------------------------------------- */

/* Create a vector index.  Idempotent: returns 0 if `name` already
 * exists, 1 on first creation, -1 on bad input. */
int dazzle_vs_create(const char *name, int dim, int M, int ef_construction, int initial_cap);

/* Add a single vector under `id`.  Returns 1 on success, negative on
 * error. */
int dazzle_vs_add(const char *name, const char *id, const float *embedding);

/* Search for the top-K nearest neighbours.  Writes distances to
 * out_dists (caller-provided buffer of length max_out) and stages the
 * result IDs as a NUL-separated stream that dazzle_vs_search_ids
 * returns.  Two-call protocol because the C ABI can't return two
 * pointers from one call cleanly.
 *
 * If ef > 0, sets the per-call HNSW ef parameter; -1 leaves the
 * index's default in place. */
int dazzle_vs_search(const char *name, const float *query, int k, int ef,
                     float *out_dists, int max_out);

/* Returns the IDs of the LAST search call, NUL-separated.  Valid only
 * until the next dazzle_* call. */
const char *dazzle_vs_search_ids(void);

/* Drop the index by name.  Returns 1 if it existed. */
int dazzle_vs_drop(const char *name);

/* ---------------------------------------------------------------- */
/* Snapshot — serialise / deserialise the full state                 */
/* ---------------------------------------------------------------- */

/* Serialise everything to an internal buffer.  *out_buf points into
 * library-owned memory; *out_len is the byte length.  Caller MUST
 * read or copy the bytes before calling any other dazzle_* function
 * (it may invalidate the buffer), and MUST call
 * dazzle_snapshot_release() when done. */
int dazzle_save_snapshot(uint8_t **out_buf, int *out_len);

/* Deserialise from a previously-saved buffer.  Replaces the current
 * in-memory state in full.  Returns 1 on success, negative codes for:
 *   -1  null input or short header
 *   -2  bad magic
 *   -3  unsupported version
 *   -4  truncated payload */
int dazzle_load_snapshot(const uint8_t *buf, int len);

/* Free the buffer obtained from dazzle_save_snapshot. */
void dazzle_snapshot_release(void);

/* ---------------------------------------------------------------- */
/* Diagnostics                                                       */
/* ---------------------------------------------------------------- */

/* Returns a NUL-terminated build identifier owned by the library. */
const char *dazzle_version(void);

/* Drop EVERYTHING in memory (hashes + vectors + snapshot buffer). */
int dazzle_clear(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* DAZZLE_LITE_H */
