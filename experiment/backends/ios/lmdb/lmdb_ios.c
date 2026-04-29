// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// lmdb_ios.c — Flat C shim around the OpenLDAP LMDB C API for iOS Swift.
//
// Mirrors the Android lmdb_jni.c bridge but with a vanilla C interface
// (no JNI envelope). Keeps a single MDB_env open for the lifetime of the
// process — same single-writer/multi-reader model used by the Kotlin side
// so the two backends produce comparable storage_only numbers.

#include "lmdb_ios.h"
#include "lmdb.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static MDB_env *g_env = NULL;

bool lmdb_ios_open(const char *path, int max_dbs, int map_size_mb) {
    if (g_env) return true;
    int rc = mdb_env_create(&g_env);
    if (rc) {
        fprintf(stderr, "[lmdb_ios] mdb_env_create: %s\n", mdb_strerror(rc));
        return false;
    }
    mdb_env_set_maxdbs(g_env, (MDB_dbi)max_dbs);
    mdb_env_set_mapsize(g_env, (size_t)map_size_mb * 1024UL * 1024UL);

    // iOS device flag set:
    //   • MDB_NOSYNC   — same as Android: ingest path stays comparable.
    //   • MDB_WRITEMAP — same as Android: pages written through mmap.
    //   • MDB_NOLOCK   — iOS-only. The Documents sandbox blocks LMDB's
    //                    fcntl(F_SETLK) on lock.mdb (lock.mdb gets created
    //                    but data.mdb never does, marker never lands).
    //                    Single-process app: lock coordination is moot.
    rc = mdb_env_open(g_env, path,
                      MDB_NOSYNC | MDB_WRITEMAP | MDB_NOLOCK, 0664);
    if (rc) {
        fprintf(stderr, "[lmdb_ios] mdb_env_open(%s): %s\n", path, mdb_strerror(rc));
        mdb_env_close(g_env);
        g_env = NULL;
        return false;
    }
    return true;
}

void lmdb_ios_close(void) {
    if (g_env) { mdb_env_close(g_env); g_env = NULL; }
}

bool lmdb_ios_sync(bool force) {
    if (!g_env) return false;
    return mdb_env_sync(g_env, force ? 1 : 0) == 0;
}

bool lmdb_ios_put(const char *db_name, const char *key, const char *value) {
    if (!g_env) return false;
    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, 0, &txn);
    if (rc) return false;

    rc = mdb_dbi_open(txn, db_name, MDB_CREATE, &dbi);
    if (rc) { mdb_txn_abort(txn); return false; }

    MDB_val mk = { .mv_size = strlen(key),   .mv_data = (void *)key   };
    MDB_val mv = { .mv_size = strlen(value), .mv_data = (void *)value };
    rc = mdb_put(txn, dbi, &mk, &mv, 0);
    if (rc) { mdb_txn_abort(txn); return false; }

    return mdb_txn_commit(txn) == 0;
}

char *lmdb_ios_get(const char *db_name, const char *key) {
    if (!g_env) return NULL;
    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, MDB_RDONLY, &txn);
    if (rc) return NULL;

    rc = mdb_dbi_open(txn, db_name, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); return NULL; }

    MDB_val mk = { .mv_size = strlen(key), .mv_data = (void *)key };
    MDB_val mv;
    char *out = NULL;
    rc = mdb_get(txn, dbi, &mk, &mv);
    if (rc == 0) {
        out = (char *)malloc(mv.mv_size + 1);
        if (out) {
            memcpy(out, mv.mv_data, mv.mv_size);
            out[mv.mv_size] = '\0';
        }
    }
    mdb_txn_abort(txn);  // read-only, abort releases handles
    return out;
}

bool lmdb_ios_delete(const char *db_name, const char *key) {
    if (!g_env) return false;
    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, 0, &txn);
    if (rc) return false;

    rc = mdb_dbi_open(txn, db_name, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); return false; }

    MDB_val mk = { .mv_size = strlen(key), .mv_data = (void *)key };
    rc = mdb_del(txn, dbi, &mk, NULL);
    if (rc && rc != MDB_NOTFOUND) { mdb_txn_abort(txn); return false; }

    int crc = mdb_txn_commit(txn);
    return crc == 0;
}

bool lmdb_ios_drop(const char *db_name) {
    if (!g_env) return false;
    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, 0, &txn);
    if (rc) return false;

    rc = mdb_dbi_open(txn, db_name, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); return false; }

    rc = mdb_drop(txn, dbi, 0);  // 0 = empty contents, keep DB handle
    if (rc) { mdb_txn_abort(txn); return false; }

    return mdb_txn_commit(txn) == 0;
}

char **lmdb_ios_get_all_keys(const char *db_name, size_t *out_count) {
    if (out_count) *out_count = 0;
    if (!g_env) return NULL;

    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    MDB_cursor *cursor = NULL;
    int rc = mdb_txn_begin(g_env, NULL, MDB_RDONLY, &txn);
    if (rc) return NULL;

    rc = mdb_dbi_open(txn, db_name, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); return NULL; }

    MDB_stat stat;
    mdb_stat(txn, dbi, &stat);
    size_t cap = stat.ms_entries;
    if (cap == 0) { mdb_txn_abort(txn); return NULL; }

    char **keys = (char **)calloc(cap, sizeof(char *));
    if (!keys) { mdb_txn_abort(txn); return NULL; }

    rc = mdb_cursor_open(txn, dbi, &cursor);
    if (rc) { free(keys); mdb_txn_abort(txn); return NULL; }

    MDB_val mk, mv;
    size_t idx = 0;
    while (idx < cap &&
           mdb_cursor_get(cursor, &mk, &mv,
                          idx == 0 ? MDB_FIRST : MDB_NEXT) == 0) {
        char *tmp = (char *)malloc(mk.mv_size + 1);
        if (!tmp) break;
        memcpy(tmp, mk.mv_data, mk.mv_size);
        tmp[mk.mv_size] = '\0';
        keys[idx++] = tmp;
    }

    mdb_cursor_close(cursor);
    mdb_txn_abort(txn);

    if (out_count) *out_count = idx;
    return keys;
}

void lmdb_ios_free_keys(char **keys, size_t count) {
    if (!keys) return;
    for (size_t i = 0; i < count; i++) free(keys[i]);
    free(keys);
}
