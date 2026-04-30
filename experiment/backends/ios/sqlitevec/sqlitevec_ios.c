// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// iOS C shim for the sqlite-vec vector benchmark. Links against:
//   - the system libsqlite3 (ship-linked via project.yml OTHER_LDFLAGS)
//   - sqlite-vec.c (vendored next to this file)
//
// We don't vendor sqlite3 amalgamation on iOS (like Android does) because the
// system SQLite on iOS 17+ is already 3.41+, which carries every public API
// sqlite-vec needs (sqlite3_vtab_in, shadow tables, module_v2). That keeps
// the iOS bench binary substantially smaller (~9 MB saved).
//
// The shim mirrors experiment/backends/android/cpp/sqlitevec/sqlitevec_jni.c
// but returns plain C results instead of jobjectArray. Swift callers pass in
// output buffers they own; we strdup id strings into out_ids[] slots and
// they free via svec_free_id.

#include "sqlitevec_ios.h"

#include <sqlite3.h>
#include "sqlite-vec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define SVLOG(fmt, ...) fprintf(stderr, "[svec] " fmt "\n", ##__VA_ARGS__)

struct SVecHandle {
    sqlite3      *db;
    int           dim;
    sqlite3_stmt *ins;
    sqlite3_stmt *sel;
};

SVecHandle *svec_open(const char *path, int dim) {
    if (!path || dim <= 0) return NULL;

    sqlite3 *db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        SVLOG("sqlite3_open(%s) failed: %s", path, sqlite3_errmsg(db));
        sqlite3_close(db);
        return NULL;
    }

    // Register vec0 on this connection. Idempotent inside a process.
    char *err = NULL;
    rc = sqlite3_vec_init(db, &err, NULL);
    if (rc != SQLITE_OK) {
        SVLOG("sqlite3_vec_init failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return NULL;
    }

    // Performance pragmas (same as Android bench).
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;",   NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);

    // Create (or reuse) the virtual table.
    char ddl[256];
    snprintf(ddl, sizeof(ddl),
             "CREATE VIRTUAL TABLE IF NOT EXISTS v_items USING vec0("
             "id TEXT PRIMARY KEY, "
             "embedding float[%d] distance_metric=cosine);",
             dim);
    rc = sqlite3_exec(db, ddl, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        SVLOG("CREATE VIRTUAL TABLE failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return NULL;
    }
    // Fresh run: truncate any rows from a previous session on the same file.
    sqlite3_exec(db, "DELETE FROM v_items;", NULL, NULL, NULL);

    SVecHandle *h = calloc(1, sizeof(SVecHandle));
    if (!h) { sqlite3_close(db); return NULL; }
    h->db  = db;
    h->dim = dim;

    rc = sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO v_items(id, embedding) VALUES (?, ?);",
            -1, &h->ins, NULL);
    if (rc != SQLITE_OK) {
        SVLOG("prepare insert failed: %s", sqlite3_errmsg(db));
        sqlite3_close(db); free(h); return NULL;
    }
    rc = sqlite3_prepare_v2(
            db,
            "SELECT id, distance FROM v_items "
            "WHERE embedding MATCH ? AND k = ? "
            "ORDER BY distance;",
            -1, &h->sel, NULL);
    if (rc != SQLITE_OK) {
        SVLOG("prepare select failed: %s", sqlite3_errmsg(db));
        sqlite3_finalize(h->ins); sqlite3_close(db); free(h); return NULL;
    }

    return h;
}

void svec_close(SVecHandle *h) {
    if (!h) return;
    if (h->ins) sqlite3_finalize(h->ins);
    if (h->sel) sqlite3_finalize(h->sel);
    if (h->db)  sqlite3_close(h->db);
    free(h);
}

void svec_begin_tx(SVecHandle *h) {
    if (h && h->db) sqlite3_exec(h->db, "BEGIN;", NULL, NULL, NULL);
}

void svec_commit_tx(SVecHandle *h) {
    if (h && h->db) sqlite3_exec(h->db, "COMMIT;", NULL, NULL, NULL);
}

void svec_add(SVecHandle *h, const char *id, int id_len,
              const float *vec, int dim) {
    if (!h || !h->ins || !vec || !id) return;
    if (dim != h->dim) return;

    sqlite3_reset(h->ins);
    sqlite3_clear_bindings(h->ins);
    sqlite3_bind_text(h->ins, 1, id, id_len, SQLITE_TRANSIENT);
    sqlite3_bind_blob(h->ins, 2, vec, dim * (int)sizeof(float),
                      SQLITE_TRANSIENT);
    int rc = sqlite3_step(h->ins);
    if (rc != SQLITE_DONE) {
        SVLOG("insert step failed: %s", sqlite3_errmsg(h->db));
    }
}

int svec_knn(SVecHandle *h, const float *query, int dim, int k,
             char **out_ids, float *out_dists, int out_cap) {
    if (!h || !h->sel || !query || !out_ids || !out_dists) return 0;
    if (dim != h->dim) return 0;
    const int limit = (k < out_cap) ? k : out_cap;
    if (limit <= 0) return 0;

    sqlite3_reset(h->sel);
    sqlite3_clear_bindings(h->sel);
    sqlite3_bind_blob(h->sel, 1, query, dim * (int)sizeof(float),
                      SQLITE_TRANSIENT);
    sqlite3_bind_int(h->sel, 2, k);

    int n = 0;
    while (n < limit && sqlite3_step(h->sel) == SQLITE_ROW) {
        const unsigned char *id = sqlite3_column_text(h->sel, 0);
        double dist = sqlite3_column_double(h->sel, 1);
        if (id) {
            // strdup the id so the caller can take ownership and free at
            // their own pace via svec_free_id.
            out_ids[n]   = strdup((const char *)id);
        } else {
            out_ids[n]   = NULL;
        }
        out_dists[n] = (float)dist;
        n++;
    }
    return n;
}

void svec_free_id(char *id) {
    if (id) free(id);
}

int64_t svec_count(SVecHandle *h) {
    if (!h || !h->db) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(h->db, "SELECT COUNT(*) FROM v_items;", -1, &st, NULL)
        != SQLITE_OK) return -1;
    int64_t n = -1;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return n;
}

int64_t svec_db_file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) return (int64_t)st.st_size;
    return -1;
}
