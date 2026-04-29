// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Tiny C facade over SQLite + sqlite-vec for the iOS vector benchmark.
// Exposed to Swift via the app's bridging header.
//
// Design mirrors the Android JNI shim in
// experiment/backends/android/cpp/sqlitevec/sqlitevec_jni.c but adapted for
// a Swift caller: no JNI, direct pointer + length on the wire, result set
// returned as a pair of parallel arrays the caller owns.
//
// Lifecycle:
//   svec_open(path, dim) → opaque handle (NULL on failure)
//   svec_close(handle)
//   svec_begin_tx / svec_commit_tx
//   svec_add(handle, id_utf8, id_len, vec, dim)
//   svec_knn(handle, query_vec, dim, k, out_ids, out_dists, out_cap) → n filled
//   svec_free_id(ptr) for each non-null out_ids[i] returned
//   svec_count(handle) → row count

#ifndef SQLITEVEC_IOS_H
#define SQLITEVEC_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct SVecHandle SVecHandle;

/// Opens (or creates) a SQLite DB at `path`, registers the vec0 module on the
/// connection, and creates the v_items virtual table with cosine distance.
/// On success returns an opaque handle; returns NULL on error.
SVecHandle *svec_open(const char *path, int dim);

/// Closes the DB and frees the handle. Safe on NULL.
void svec_close(SVecHandle *h);

/// Begins/commits a transaction (wraps BEGIN / COMMIT).
void svec_begin_tx(SVecHandle *h);
void svec_commit_tx(SVecHandle *h);

/// Inserts one vector. `vec` is fp32, `dim` floats long. `id` is a UTF-8 key.
void svec_add(SVecHandle *h, const char *id, int id_len,
              const float *vec, int dim);

/// Runs a kNN search. Fills `out_ids[0..n-1]` with heap-allocated C strings
/// (caller must free each via svec_free_id) and `out_dists[0..n-1]` with
/// float distances. `out_cap` is the caller-provided capacity of both arrays;
/// at most min(k, out_cap) rows are written. Returns the number of rows
/// written.
int svec_knn(SVecHandle *h, const float *query, int dim, int k,
             char **out_ids, float *out_dists, int out_cap);

/// Frees a single id string previously returned by svec_knn.
void svec_free_id(char *id);

/// Returns the row count in v_items, or -1 on error.
int64_t svec_count(SVecHandle *h);

/// Size in bytes of the on-disk DB file (or -1 if it doesn't exist).
int64_t svec_db_file_size(const char *path);

#ifdef __cplusplus
}
#endif

#endif  // SQLITEVEC_IOS_H
