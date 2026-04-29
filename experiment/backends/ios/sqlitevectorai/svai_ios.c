// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// iOS C shim for the SQLiteAI sqlite-vector extension benchmark.
//
// **Why we vendor sqlite3 here.** Apple's libsqlite3.dylib ships with
// extension loading disabled — `sqlite3_load_extension` and
// `sqlite3_enable_load_extension` are not exported, and
// `sqlite3_auto_extension` returns SQLITE_MISUSE. The SQLiteAI
// `vector.framework` extension expects to be loaded into a SQLite
// connection that exposes a real `sqlite3_api_routines*` (it stores it
// in its private static `sqlite3_api`), so we have to use a SQLite
// build that supports load_extension.
//
// To avoid an ABI clash with the system libsqlite3 used by every
// other backend in the same app process, we vendor the SQLite
// amalgamation INSIDE this single compilation unit: `#include
// "sqlite3.c"` brings the entire SQLite implementation into our
// translation unit at file scope, with `SQLITE_API` redefined to
// `__attribute__((visibility("hidden")))` so none of those symbols
// leak out of svai_ios.o. The rest of the app keeps linking against
// `-lsqlite3` (system) — no duplicate-symbol errors at link time.
//
// Lifecycle:
//   1. svai_open(db_path, ext_path, dim)
//      a. sqlite3_open(db_path, &db)            — bundled
//      b. sqlite3_enable_load_extension(db, 1)  — bundled
//      c. sqlite3_load_extension(db,
//             ext_path, "sqlite3_vector_init", &err)
//         The bundled SQLite dlopens the framework binary, locates
//         `sqlite3_vector_init`, builds a sqlite3_api_routines table
//         pointing at the bundled SQLite, and calls the entry point.
//         The extension stores that routines pointer and registers
//         its SQL functions (vector_init, vector_quantize, etc.) on
//         this connection.
//      d. CREATE TABLE emb(id INTEGER PRIMARY KEY, vector BLOB);
//      e. SELECT vector_init('emb','vector','dimension=...,type=FLOAT32,distance=cosine');
//   2. svai_add(handle, rowid, vec, dim)        — INSERT into emb
//   3. svai_finalize_index_ex                   — vector_quantize + preload
//   4. svai_knn                                 — vector_quantize_scan

// ----- bundled sqlite3 build flags (must precede sqlite3.c include) ------

// Hide all sqlite3 symbols from this object's exported symbol table.
// This is the trick that prevents collisions with system libsqlite3:
// every `SQLITE_API` declaration in sqlite3.c becomes a hidden symbol,
// callable only from within this translation unit.
#define SQLITE_API           __attribute__((visibility("hidden"))) extern
#define SQLITE_PRIVATE       __attribute__((visibility("hidden"))) static

// Required for sqlite3_load_extension / sqlite3_enable_load_extension.
#define SQLITE_ENABLE_LOAD_EXTENSION 1

// Sane defaults that match Apple's compiled libsqlite3 settings, so the
// behaviour the rest of the bench observes (WAL mode, threading, etc.)
// stays comparable.
#define SQLITE_THREADSAFE             1
#define SQLITE_DEFAULT_WAL_SYNCHRONOUS 1
#define SQLITE_OMIT_DEPRECATED        1
#define SQLITE_OMIT_SHARED_CACHE      1
#define SQLITE_DQS                    0
#define HAVE_USLEEP                   1

// `sqlite3.c` references `localtime_r` which is in <time.h>; iOS has it
// but only when _XOPEN_SOURCE / POSIX feature macros are set. Set them
// before the amalgamation pulls in libc headers.
#define _XOPEN_SOURCE 700

// Bring the entire SQLite implementation into this compilation unit.
// 6.4 MB of C, ~250k LOC, but the visibility=hidden guard keeps it
// contained. Compiler will eliminate dead code; final size in the app
// binary is comparable to the system libsqlite3 dyld load anyway.
#include "sqlite3.c"

// ----- bench shim -----

#include "svai_ios.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define SVAILOG(fmt, ...) fprintf(stderr, "[svai] " fmt "\n", ##__VA_ARGS__)

struct SVaiHandle {
    sqlite3      *db;
    int           dim;
    sqlite3_stmt *ins;
    sqlite3_stmt *sel;
};

// We do NOT use sqlite3_auto_extension on iOS — Apple's loader compiled
// out auto-extensions. Each connection loads the extension explicitly
// inside svai_open via sqlite3_load_extension.

SVaiHandle *svai_open(const char *path, const char *ext_path, int dim) {
    if (!path || !ext_path || dim <= 0) {
        SVAILOG("svai_open: invalid args (path=%p ext=%p dim=%d)",
                (void*)path, (void*)ext_path, dim);
        return NULL;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        SVAILOG("sqlite3_open(%s) failed: %s", path, sqlite3_errmsg(db));
        sqlite3_close(db);
        return NULL;
    }

    // Allow `sqlite3_load_extension` for THIS connection only — SQLite
    // has a soft API gate on top of the compile-time flag. We turn it
    // back off after the extension is loaded so stray application SQL
    // can't load arbitrary dylibs through this handle.
    rc = sqlite3_enable_load_extension(db, 1);
    if (rc != SQLITE_OK) {
        SVAILOG("enable_load_extension failed: %s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return NULL;
    }

    char *err = NULL;
    rc = sqlite3_load_extension(db, ext_path, "sqlite3_vector_init", &err);
    if (rc != SQLITE_OK) {
        SVAILOG("sqlite3_load_extension(%s) failed: %s",
                ext_path, err ? err : sqlite3_errmsg(db));
        sqlite3_free(err);
        sqlite3_close(db);
        return NULL;
    }
    sqlite3_enable_load_extension(db, 0);

    // Sanity check the extension actually registered the SQL surface.
    {
        sqlite3_stmt *st = NULL;
        int prc = sqlite3_prepare_v2(db,
                "SELECT 1 FROM pragma_function_list "
                "WHERE name='vector_init' LIMIT 1;",
                -1, &st, NULL);
        int found = 0;
        if (prc == SQLITE_OK && st) {
            if (sqlite3_step(st) == SQLITE_ROW) found = 1;
        }
        sqlite3_finalize(st);
        if (!found) {
            SVAILOG("vector_init function NOT registered after load_extension");
            sqlite3_close(db);
            return NULL;
        }
    }

    // Fair-play pragmas (mirrors the sqlitevec backend).
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;",   NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);

    rc = sqlite3_exec(db,
            "CREATE TABLE IF NOT EXISTS emb("
            " id INTEGER PRIMARY KEY, vector BLOB);",
            NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        SVAILOG("CREATE TABLE failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return NULL;
    }
    sqlite3_exec(db, "DELETE FROM emb;", NULL, NULL, NULL);

    char init_sql[192];
    snprintf(init_sql, sizeof(init_sql),
             "SELECT vector_init('emb', 'vector', "
             "'dimension=%d,type=FLOAT32,distance=cosine');",
             dim);
    rc = sqlite3_exec(db, init_sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        SVAILOG("vector_init failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return NULL;
    }

    SVaiHandle *h = (SVaiHandle *)calloc(1, sizeof(SVaiHandle));
    if (!h) { sqlite3_close(db); return NULL; }
    h->db = db; h->dim = dim;

    rc = sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO emb(id, vector) VALUES(?, ?);",
            -1, &h->ins, NULL);
    if (rc != SQLITE_OK) {
        SVAILOG("prepare insert failed: %s", sqlite3_errmsg(db));
        sqlite3_close(db); free(h); return NULL;
    }
    rc = sqlite3_prepare_v2(db,
            "SELECT rowid, distance FROM "
            "vector_quantize_scan('emb', 'vector', ?, ?);",
            -1, &h->sel, NULL);
    if (rc != SQLITE_OK) {
        SVAILOG("prepare select failed: %s", sqlite3_errmsg(db));
        sqlite3_finalize(h->ins); sqlite3_close(db); free(h); return NULL;
    }

    return h;
}

void svai_close(SVaiHandle *h) {
    if (!h) return;
    if (h->ins) sqlite3_finalize(h->ins);
    if (h->sel) sqlite3_finalize(h->sel);
    if (h->db)  sqlite3_close(h->db);
    free(h);
}

void svai_begin_tx(SVaiHandle *h) {
    if (h && h->db) sqlite3_exec(h->db, "BEGIN;", NULL, NULL, NULL);
}
void svai_commit_tx(SVaiHandle *h) {
    if (h && h->db) sqlite3_exec(h->db, "COMMIT;", NULL, NULL, NULL);
}

void svai_add(SVaiHandle *h, int64_t rowid, const float *vec, int dim) {
    if (!h || !h->ins || !vec) return;
    if (dim != h->dim) return;

    sqlite3_reset(h->ins);
    sqlite3_clear_bindings(h->ins);
    sqlite3_bind_int64(h->ins, 1, (sqlite3_int64)rowid);
    sqlite3_bind_blob(h->ins, 2, vec, dim * (int)sizeof(float),
                      SQLITE_TRANSIENT);
    int rc = sqlite3_step(h->ins);
    if (rc != SQLITE_DONE) {
        SVAILOG("insert step failed: %s", sqlite3_errmsg(h->db));
    }
}

int svai_finalize_index_ex(SVaiHandle *h, int max_memory_mb, int preload) {
    if (!h || !h->db) return -1;
    if (max_memory_mb <= 0) max_memory_mb = 50;
    char *err = NULL;
    char sql[128];
    snprintf(sql, sizeof(sql),
             "SELECT vector_quantize('emb', 'vector', 'max_memory=%dMB');",
             max_memory_mb);
    int rc = sqlite3_exec(h->db, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        SVAILOG("vector_quantize failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        return rc;
    }
    if (preload) {
        // preload is a hot-cache hint — ignore failure.
        sqlite3_exec(h->db,
                "SELECT vector_quantize_preload('emb', 'vector');",
                NULL, NULL, NULL);
    }
    return SQLITE_OK;
}

int svai_finalize_index(SVaiHandle *h) {
    return svai_finalize_index_ex(h, 50, 1);
}

int svai_knn(SVaiHandle *h, const float *query, int dim, int k,
             int64_t *out_rowids, float *out_dists, int out_cap) {
    if (!h || !h->sel || !query || !out_rowids || !out_dists) return 0;
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
        out_rowids[n] = (int64_t)sqlite3_column_int64(h->sel, 0);
        out_dists[n]  = (float)sqlite3_column_double(h->sel, 1);
        n++;
    }
    return n;
}

int64_t svai_count(SVaiHandle *h) {
    if (!h || !h->db) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(h->db, "SELECT COUNT(*) FROM emb;", -1, &st, NULL)
        != SQLITE_OK) return -1;
    int64_t n = -1;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return n;
}

int64_t svai_db_file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) return (int64_t)st.st_size;
    return -1;
}
