// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// iOS C facade over SQLite + the SQLiteAI `sqlite-vector` extension for the
// dazzle vector benchmark. Mirrors the Android JNI shim semantically —
// same CREATE TABLE / vector_init / vector_quantize / vector_quantize_scan
// sequence, same API surface Swift sees.
//
// The extension binary is Elastic License 2.0 (bench-only, never shipped
// inside the dazzle SDK itself). On iOS it ships as vector.xcframework
// from https://github.com/sqliteai/sqlite-vector.
//
// Lifecycle:
//   svai_open(path, dim) → opaque handle (NULL on failure)
//   svai_close(handle)
//   svai_begin_tx / svai_commit_tx
//   svai_add(handle, rowid, vec, dim)
//   svai_finalize_index(handle)   ← mandatory before first search
//   svai_knn(handle, query, dim, k, out_rowids, out_dists, out_cap)
//   svai_count(handle) / svai_db_file_size(path)

#ifndef SVAI_IOS_H
#define SVAI_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct SVaiHandle SVaiHandle;

/// Open (or create) a SQLite DB at `path`, load the sqlite-vector
/// extension binary at `ext_path`, create the `emb(id INTEGER PRIMARY KEY,
/// vector BLOB)` table and register the column via `vector_init`. Returns
/// NULL on error.
///
/// `ext_path` must point to the vector.framework binary inside the
/// embedded private frameworks dir (typically
/// `<app.app>/Frameworks/vector.framework/vector` on device or
/// `<app.app>/Frameworks/vector.framework/vector` inside the simulator
/// `.app` bundle). Pass NULL only when calling under a SQLite build that
/// already has the extension auto-registered (not the case on iOS — see
/// the `sqlite3_load_extension` dance in svai_ios.c).
SVaiHandle *svai_open(const char *path, const char *ext_path, int dim);

/// Close and free the handle (safe on NULL).
void svai_close(SVaiHandle *h);

void svai_begin_tx(SVaiHandle *h);
void svai_commit_tx(SVaiHandle *h);

/// Insert one vector with an explicit integer rowid. `vec` is fp32,
/// `dim` floats long (caller already normalized if required).
void svai_add(SVaiHandle *h, int64_t rowid, const float *vec, int dim);

/// Build the quantized snapshot SQLiteAI needs before scans. Without this
/// `vector_quantize_scan` returns zero rows per their own API.md, so this
/// call is mandatory — its cost is included in the reported ingest time.
/// Returns 0 on success, non-zero sqlite3 rc on failure.
int svai_finalize_index(SVaiHandle *h);
int svai_finalize_index_ex(SVaiHandle *h, int max_memory_mb, int preload);

/// kNN scan via `vector_quantize_scan`. Writes up to min(k, out_cap)
/// rowids + distances into the caller-owned arrays, returns the number
/// written. Caller owns nothing beyond the arrays they passed in
/// (no per-row heap allocations).
int svai_knn(SVaiHandle *h, const float *query, int dim, int k,
             int64_t *out_rowids, float *out_dists, int out_cap);

int64_t svai_count(SVaiHandle *h);
int64_t svai_db_file_size(const char *path);

#ifdef __cplusplus
}
#endif

#endif  // SVAI_IOS_H
