// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// rocksdb_ios.c — Flat C shim for RocksDB on iOS. Wraps the stable
// `rocksdb/c.h` API exposed by libRocksDB.a in a way that mirrors
// rocksdb_jni.cpp on Android. One global handle, default WriteOptions,
// no column families (we use a single key prefix to simulate sub-DBs,
// matching the Android JNI bridge).

#include "rocksdb_ios.h"
#include "rocksdb/c.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static rocksdb_t *g_db = NULL;
static rocksdb_options_t *g_opts = NULL;
static rocksdb_writeoptions_t *g_wopts = NULL;
static rocksdb_readoptions_t *g_ropts = NULL;

static void log_err(const char *what, char *err) {
    if (err) {
        fprintf(stderr, "[rocksdb_ios] %s: %s\n", what, err);
        rocksdb_free(err);
    }
}

bool rocksdb_ios_open(const char *path) {
    if (g_db) return true;

    g_opts = rocksdb_options_create();
    rocksdb_options_set_create_if_missing(g_opts, 1);
    rocksdb_options_set_compression(g_opts, rocksdb_no_compression);
    rocksdb_options_set_max_background_jobs(g_opts, 1);
    rocksdb_options_set_write_buffer_size(g_opts, 4 * 1024 * 1024);

    g_wopts = rocksdb_writeoptions_create();
    g_ropts = rocksdb_readoptions_create();

    char *err = NULL;
    g_db = rocksdb_open(g_opts, path, &err);
    if (err || !g_db) {
        log_err("rocksdb_open", err);
        rocksdb_options_destroy(g_opts);          g_opts  = NULL;
        rocksdb_writeoptions_destroy(g_wopts);    g_wopts = NULL;
        rocksdb_readoptions_destroy(g_ropts);     g_ropts = NULL;
        if (g_db) { rocksdb_close(g_db); g_db = NULL; }
        return false;
    }
    return true;
}

void rocksdb_ios_close(void) {
    if (g_db)    { rocksdb_close(g_db); g_db = NULL; }
    if (g_wopts) { rocksdb_writeoptions_destroy(g_wopts); g_wopts = NULL; }
    if (g_ropts) { rocksdb_readoptions_destroy(g_ropts);  g_ropts = NULL; }
    if (g_opts)  { rocksdb_options_destroy(g_opts);       g_opts  = NULL; }
}

bool rocksdb_ios_put(const char *key, const char *value) {
    if (!g_db) return false;
    char *err = NULL;
    rocksdb_put(g_db, g_wopts, key, strlen(key), value, strlen(value), &err);
    if (err) { log_err("rocksdb_put", err); return false; }
    return true;
}

char *rocksdb_ios_get(const char *key) {
    if (!g_db) return NULL;
    char *err = NULL;
    size_t vlen = 0;
    char *raw = rocksdb_get(g_db, g_ropts, key, strlen(key), &vlen, &err);
    if (err) { log_err("rocksdb_get", err); return NULL; }
    if (!raw) return NULL;
    char *out = (char *)malloc(vlen + 1);
    if (out) {
        memcpy(out, raw, vlen);
        out[vlen] = '\0';
    }
    rocksdb_free(raw);
    return out;
}

bool rocksdb_ios_delete(const char *key) {
    if (!g_db) return false;
    char *err = NULL;
    rocksdb_delete(g_db, g_wopts, key, strlen(key), &err);
    if (err) { log_err("rocksdb_delete", err); return false; }
    return true;
}

char **rocksdb_ios_get_keys_with_prefix(const char *prefix, size_t *out_count) {
    if (out_count) *out_count = 0;
    if (!g_db) return NULL;

    rocksdb_iterator_t *it = rocksdb_create_iterator(g_db, g_ropts);
    if (!it) return NULL;

    size_t plen = strlen(prefix);
    rocksdb_iter_seek(it, prefix, plen);

    size_t cap = 64, n = 0;
    char **keys = (char **)malloc(cap * sizeof(char *));
    if (!keys) { rocksdb_iter_destroy(it); return NULL; }

    while (rocksdb_iter_valid(it)) {
        size_t klen = 0;
        const char *kp = rocksdb_iter_key(it, &klen);
        if (klen < plen || memcmp(kp, prefix, plen) != 0) break;

        if (n >= cap) {
            cap *= 2;
            char **grown = (char **)realloc(keys, cap * sizeof(char *));
            if (!grown) break;
            keys = grown;
        }
        char *copy = (char *)malloc(klen + 1);
        if (!copy) break;
        memcpy(copy, kp, klen);
        copy[klen] = '\0';
        keys[n++] = copy;

        rocksdb_iter_next(it);
    }

    rocksdb_iter_destroy(it);
    if (out_count) *out_count = n;
    return keys;
}

int rocksdb_ios_delete_with_prefix(const char *prefix) {
    if (!g_db) return 0;

    rocksdb_writebatch_t *batch = rocksdb_writebatch_create();
    rocksdb_iterator_t *it = rocksdb_create_iterator(g_db, g_ropts);
    if (!it || !batch) {
        if (it) rocksdb_iter_destroy(it);
        if (batch) rocksdb_writebatch_destroy(batch);
        return 0;
    }

    size_t plen = strlen(prefix);
    rocksdb_iter_seek(it, prefix, plen);
    int count = 0;

    while (rocksdb_iter_valid(it)) {
        size_t klen = 0;
        const char *kp = rocksdb_iter_key(it, &klen);
        if (klen < plen || memcmp(kp, prefix, plen) != 0) break;
        rocksdb_writebatch_delete(batch, kp, klen);
        count++;
        rocksdb_iter_next(it);
    }

    rocksdb_iter_destroy(it);

    if (count > 0) {
        char *err = NULL;
        rocksdb_write(g_db, g_wopts, batch, &err);
        if (err) { log_err("rocksdb_write(batch)", err); count = 0; }
    }
    rocksdb_writebatch_destroy(batch);
    return count;
}

void rocksdb_ios_free_keys(char **keys, size_t count) {
    if (!keys) return;
    for (size_t i = 0; i < count; i++) free(keys[i]);
    free(keys);
}
