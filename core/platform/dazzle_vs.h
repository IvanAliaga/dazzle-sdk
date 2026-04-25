/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * dazzle_vs.h — plain-C surface for the vector-search module.
 *
 * Mirror of the JNI-bound entry points in
 * sdk/android/src/main/cpp/valkeysearch_module.cc. iOS (Swift) consumes
 * these through `import DazzleC`; Android keeps the JNI symbols for
 * backward compat with the Kotlin `VectorIndex` native methods.
 *
 * All functions return opaque handles as `void*` (resolved internally to
 * the C++ `VectorSchema*`). The handle stays valid for the lifetime of
 * the index — i.e. until someone executes FT.DROPINDEX on the same name
 * — and must never be dereferenced outside the helpers.
 *
 * Search functions write ids into caller-provided `char**` slots. Each
 * populated slot is a malloc'd NUL-terminated string — free every non-
 * NULL entry with `dazzle_vs_free_id` or the host process leaks.
 */

#ifndef DAZZLE_VS_H
#define DAZZLE_VS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Create an HNSW index that stores int8[dim] per point (SQ8). Cosine is
 * the only metric — per-vector quantisation scale is implicit so no per-
 * row scale needs to be persisted. `rerank != 0` keeps a parallel
 * unit-normalised fp32 side-store and re-scores the top-k·2 candidates
 * with simsimd_dot_f32 at search time. Returns NULL on failure (e.g.
 * `dim <= 0` or DAZZLE_VECTOR_SIMSIMD unavailable). If an index with
 * this name already exists the existing handle is returned unchanged. */
void *dazzle_vs_create_sq8(const char *name, int dim, int M, int efC,
                           int initialCap, int rerank);

/* FP16 variant — storage is uint16[dim]. armv8.2-a+fp16 runs FMLA on
 * fp16 lanes so the distance kernel is fast even without rerank. Same
 * lifecycle semantics as dazzle_vs_create_sq8. */
void *dazzle_vs_create_f16(const char *name, int dim, int M, int efC,
                           int initialCap);

/* Resolve an existing index name to a handle. Returns NULL when the
 * index has not been created (e.g. via FT.CREATE or a previous
 * dazzle_vs_create_* call). Safe to call from any thread. */
void *dazzle_vs_open_handle(const char *name);

/* Single-vector add on a named index. `key_len >= 0` specifies the byte
 * length of the key (binary-safe); pass `-1` when `key` is NUL-
 * terminated and the helper should compute the length. `vec` points to
 * `schema_dim` fp32 values. */
void dazzle_vs_add_direct(const char *name, const char *key, int key_len,
                          const float *vec);

/* Batch add — n_vecs contiguous fp32 rows in `vecs_flat` of
 * `n_vecs * schema_dim` elements. `ids[i]` is the key for row i.
 * `id_lens` may be NULL in which case the helper calls strlen on each
 * id. Runs the two-phase label-alloc + parallel addPoint flow
 * internally; caller does not need to hold any external mutex. */
void dazzle_vs_add_batch_direct(const char *name, int n_vecs,
                                const char *const *ids, const int *id_lens,
                                const float *vecs_flat);

/* Handle-based k-NN search. `query` holds `schema_dim` fp32 values.
 * `ef > 0` switches to hnswlib's per-call `searchKnnEf` overload
 * (thread-safe; no shared mutation), while `ef <= 0` uses
 * `index->searchKnn` with the default ef. `out_ids` and `out_dists`
 * must each point to `max_out` slots; on return slots `[0, rv)` are
 * populated with malloc'd strings + distances. Free each id with
 * `dazzle_vs_free_id`. */
int dazzle_vs_search_handle(void *handle, const float *query, int k, int ef,
                            char **out_ids, float *out_dists, int max_out);

/* Name-resolving variant. Equivalent to
 * `dazzle_vs_search_handle(dazzle_vs_open_handle(name), …)` but saves
 * one g_index_mutex round-trip per call and validates the handle
 * atomically. */
int dazzle_vs_search_direct(const char *name, const float *query, int k,
                            int ef, char **out_ids, float *out_dists,
                            int max_out);

/* Free one id string returned by dazzle_vs_search_*. NULL is a no-op. */
void dazzle_vs_free_id(char *id);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* DAZZLE_VS_H */
