// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0
//
// Minimal JNI wrapper for a SQLite + sqlite-vec benchmark backend.
//
// Why this exists instead of loading sqlite-vec as an extension:
//   Android's bundled SQLite (via android.database.sqlite.*) does not expose
//   sqlite3_enable_load_extension() to Java. Requery's sqlite-android does,
//   but it drags a second JDBC-shaped API into the app. Statically linking
//   the SQLite amalgamation + sqlite-vec amalgamation into a single .so with
//   a tiny C shim is simpler, gives us direct sqlite3_bind_blob for vectors
//   (no base64 dance), and isolates the benchmark from system SQLite quirks.
//
// The API below is just enough for the vector benchmark harness:
//   open(path, dim)      → handle
//   close(handle)
//   beginTx/commitTx     → wraps BEGIN / COMMIT
//   add(handle, id, vec) → INSERT INTO v_items(..., embedding=?)
//   knn(handle, q, k)    → SELECT ... FROM v_items WHERE embedding MATCH ? AND k=?
//                          returns parallel arrays of ids + distances
//
// Schema:
//   CREATE VIRTUAL TABLE v_items USING vec0(
//       id    TEXT PRIMARY KEY,
//       embedding FLOAT[dim]
//   );

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sqlite3.h"
#include "sqlite-vec.h"

#define VEC_LOG_TAG "SqliteVecJNI"
#include <android/log.h>
#define VLOGE(fmt, ...) \
    __android_log_print(ANDROID_LOG_ERROR, VEC_LOG_TAG, fmt, ##__VA_ARGS__)

// ── Handle layout ────────────────────────────────────────────────────────────
typedef struct {
    sqlite3      *db;
    int           dim;
    sqlite3_stmt *ins;  // INSERT OR REPLACE INTO v_items(id, embedding) VALUES (?, ?)
    sqlite3_stmt *sel;  // SELECT id, distance FROM v_items WHERE embedding MATCH ? AND k=? ORDER BY distance
} SVHandle;

static jlong h_to_j(SVHandle *h) { return (jlong)(intptr_t)h; }
static SVHandle *j_to_h(jlong j) { return (SVHandle *)(intptr_t)j; }

// ── JNI: open ────────────────────────────────────────────────────────────────
JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nOpen(
        JNIEnv *env, jclass cls, jstring jpath, jint dim) {
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);

    sqlite3 *db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        VLOGE("sqlite3_open(%s) failed: %s", path, sqlite3_errmsg(db));
        sqlite3_close(db);
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        return 0;
    }
    (*env)->ReleaseStringUTFChars(env, jpath, path);

    // Register vec0 module (no-op if already registered this process).
    char *err = NULL;
    rc = sqlite3_vec_init(db, &err, NULL);
    if (rc != SQLITE_OK) {
        VLOGE("sqlite3_vec_init failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return 0;
    }

    // Performance pragmas — apples-to-apples with the stock SQLite baseline.
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;",   NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);

    // Create (or reuse) the virtual table.
    char ddl[256];
    snprintf(ddl, sizeof(ddl),
             "CREATE VIRTUAL TABLE IF NOT EXISTS v_items USING vec0("
             "id TEXT PRIMARY KEY, "
             "embedding float[%d] distance_metric=cosine);",
             (int)dim);
    rc = sqlite3_exec(db, ddl, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        VLOGE("CREATE VIRTUAL TABLE failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return 0;
    }
    // Fresh run: truncate any rows from a previous session.
    sqlite3_exec(db, "DELETE FROM v_items;", NULL, NULL, NULL);

    SVHandle *h = (SVHandle *)calloc(1, sizeof(SVHandle));
    h->db  = db;
    h->dim = (int)dim;

    rc = sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO v_items(id, embedding) VALUES (?, ?);",
            -1, &h->ins, NULL);
    if (rc != SQLITE_OK) {
        VLOGE("prepare insert failed: %s", sqlite3_errmsg(db));
        sqlite3_close(db); free(h); return 0;
    }
    rc = sqlite3_prepare_v2(
            db,
            "SELECT id, distance FROM v_items "
            "WHERE embedding MATCH ? AND k = ? "
            "ORDER BY distance;",
            -1, &h->sel, NULL);
    if (rc != SQLITE_OK) {
        VLOGE("prepare select failed: %s", sqlite3_errmsg(db));
        sqlite3_finalize(h->ins); sqlite3_close(db); free(h); return 0;
    }

    return h_to_j(h);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nClose(
        JNIEnv *env, jclass cls, jlong handle) {
    SVHandle *h = j_to_h(handle);
    if (!h) return;
    if (h->ins) sqlite3_finalize(h->ins);
    if (h->sel) sqlite3_finalize(h->sel);
    if (h->db)  sqlite3_close(h->db);
    free(h);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nBeginTx(
        JNIEnv *env, jclass cls, jlong handle) {
    SVHandle *h = j_to_h(handle);
    if (h && h->db) sqlite3_exec(h->db, "BEGIN;", NULL, NULL, NULL);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nCommitTx(
        JNIEnv *env, jclass cls, jlong handle) {
    SVHandle *h = j_to_h(handle);
    if (h && h->db) sqlite3_exec(h->db, "COMMIT;", NULL, NULL, NULL);
}

// vector passed as a direct ByteBuffer of FLOAT32 little-endian, length = dim*4.
JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nAdd(
        JNIEnv *env, jclass cls, jlong handle,
        jstring jid, jobject jvecBuf) {
    SVHandle *h = j_to_h(handle);
    if (!h) return;
    const char *id = (*env)->GetStringUTFChars(env, jid, NULL);
    void *vptr = (*env)->GetDirectBufferAddress(env, jvecBuf);
    jlong  vlen = (*env)->GetDirectBufferCapacity(env, jvecBuf);

    sqlite3_reset(h->ins);
    sqlite3_clear_bindings(h->ins);
    sqlite3_bind_text (h->ins, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_blob (h->ins, 2, vptr, (int)vlen, SQLITE_TRANSIENT);
    int rc = sqlite3_step(h->ins);
    if (rc != SQLITE_DONE) {
        VLOGE("insert step failed: %s", sqlite3_errmsg(h->db));
    }
    (*env)->ReleaseStringUTFChars(env, jid, id);
}

// Returns a String[] of results in interleaved form: [id0, score0, id1, score1, ...].
// Score is sqlite-vec's `distance` — smaller = closer.
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nKnn(
        JNIEnv *env, jclass cls, jlong handle,
        jobject jqBuf, jint k) {
    SVHandle *h = j_to_h(handle);
    if (!h) return NULL;
    void *qptr = (*env)->GetDirectBufferAddress(env, jqBuf);
    jlong qlen = (*env)->GetDirectBufferCapacity(env, jqBuf);

    sqlite3_reset(h->sel);
    sqlite3_clear_bindings(h->sel);
    sqlite3_bind_blob(h->sel, 1, qptr, (int)qlen, SQLITE_TRANSIENT);
    sqlite3_bind_int (h->sel, 2, (int)k);

    // Collect into a growable buffer; k is small (≤100) so we over-allocate.
    int cap = (int)k * 2 + 2;
    jclass strCls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray out = (*env)->NewObjectArray(env, cap, strCls, NULL);
    int n = 0;
    while (sqlite3_step(h->sel) == SQLITE_ROW && n + 1 < cap) {
        const unsigned char *id = sqlite3_column_text(h->sel, 0);
        double dist = sqlite3_column_double(h->sel, 1);
        jstring jId = (*env)->NewStringUTF(env, (const char *)id);
        char buf[64];
        snprintf(buf, sizeof(buf), "%.9g", dist);
        jstring jDist = (*env)->NewStringUTF(env, buf);
        (*env)->SetObjectArrayElement(env, out, n++, jId);
        (*env)->SetObjectArrayElement(env, out, n++, jDist);
        (*env)->DeleteLocalRef(env, jId);
        (*env)->DeleteLocalRef(env, jDist);
    }
    // Trim by returning the prefix via a fresh array sized exactly n.
    jobjectArray trimmed = (*env)->NewObjectArray(env, n, strCls, NULL);
    for (int i = 0; i < n; i++) {
        jobject e = (*env)->GetObjectArrayElement(env, out, i);
        (*env)->SetObjectArrayElement(env, trimmed, i, e);
        (*env)->DeleteLocalRef(env, e);
    }
    return trimmed;
}

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_SqliteVecVector_nCount(
        JNIEnv *env, jclass cls, jlong handle) {
    SVHandle *h = j_to_h(handle);
    if (!h) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(h->db, "SELECT COUNT(*) FROM v_items;", -1, &st, NULL)
        != SQLITE_OK) return -1;
    jlong n = -1;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return n;
}
