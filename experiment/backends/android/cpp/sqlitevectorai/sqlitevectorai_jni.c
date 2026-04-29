// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// JNI shim for the SQLiteAI sqlite-vector extension benchmark.
//
// Unlike our sqlitevec-jni target (which statically links sqlite-vec), this
// target statically links SQLite *with* SQLITE_ENABLE_LOAD_EXTENSION so we
// can dlopen the pre-built libvector.so that ships in sqliteai's AAR. The
// extension is Elastic License 2.0 — benchmark-only, never shipped in the
// dazzle SDK itself.
//
// SQL surface (per SQLiteAI API.md — vector_init is 3-arg, table-scoped):
//   CREATE TABLE emb(id INTEGER PRIMARY KEY, vector BLOB);
//   SELECT vector_init('emb', 'vector', 'dimension=<dim>,type=FLOAT32,distance=cosine');
//   INSERT INTO emb(id, vector) VALUES(?, ?);                    -- raw FLOAT32 blob
//   SELECT rowid, distance FROM vector_quantize_scan('emb', 'vector', ?, ?);

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sqlite3.h"

#include <android/log.h>
#define LOG_TAG "SqliteVectorAIJNI"
#define LOGE(fmt, ...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, fmt, ##__VA_ARGS__)

typedef struct {
    sqlite3      *db;
    int           dim;
    sqlite3_stmt *ins;
    sqlite3_stmt *sel;
} Handle;

static jlong h_to_j(Handle *h) { return (jlong)(intptr_t)h; }
static Handle *j_to_h(jlong j) { return (Handle *)(intptr_t)j; }

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nOpen(
        JNIEnv *env, jclass cls, jstring jpath, jint dim) {
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);

    sqlite3 *db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        LOGE("sqlite3_open(%s) failed: %s", path, sqlite3_errmsg(db));
        sqlite3_close(db);
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        return 0;
    }
    (*env)->ReleaseStringUTFChars(env, jpath, path);

    // Load the SQLiteAI extension.
    sqlite3_enable_load_extension(db, 1);
    char *err = NULL;
    // "libvector" — Android's linker prepends nothing since it's already lib*.so.
    // We pass the unqualified name so dlopen uses the app's native-lib dir.
    rc = sqlite3_load_extension(db, "libvector.so", "sqlite3_vector_init", &err);
    if (rc != SQLITE_OK) {
        LOGE("load_extension libvector.so failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return 0;
    }

    // Performance pragmas — same as sqlitevec backend for fairness.
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;",   NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);

    rc = sqlite3_exec(db,
            "CREATE TABLE IF NOT EXISTS emb(id INTEGER PRIMARY KEY, vector BLOB);",
            NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        LOGE("CREATE TABLE failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return 0;
    }
    sqlite3_exec(db, "DELETE FROM emb;", NULL, NULL, NULL);

    // vector_init must run AFTER the table exists; it registers the BLOB
    // column so later SELECT vector_quantize_scan(...) knows the dim/type/
    // metric. Third arg is a free-form comma-separated options string.
    char init_sql[160];
    snprintf(init_sql, sizeof(init_sql),
             "SELECT vector_init('emb', 'vector', "
             "'dimension=%d,type=FLOAT32,distance=cosine');",
             (int)dim);
    rc = sqlite3_exec(db, init_sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        LOGE("vector_init failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        sqlite3_close(db);
        return 0;
    }

    Handle *h = (Handle *)calloc(1, sizeof(Handle));
    h->db  = db;
    h->dim = (int)dim;

    rc = sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO emb(id, vector) VALUES(?, ?);",
            -1, &h->ins, NULL);
    if (rc != SQLITE_OK) {
        LOGE("prepare insert failed: %s", sqlite3_errmsg(db));
        sqlite3_close(db); free(h); return 0;
    }
    rc = sqlite3_prepare_v2(db,
            "SELECT rowid, distance FROM vector_quantize_scan('emb', 'vector', ?, ?);",
            -1, &h->sel, NULL);
    if (rc != SQLITE_OK) {
        LOGE("prepare select failed: %s", sqlite3_errmsg(db));
        sqlite3_finalize(h->ins); sqlite3_close(db); free(h); return 0;
    }

    return h_to_j(h);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nClose(
        JNIEnv *env, jclass cls, jlong handle) {
    Handle *h = j_to_h(handle);
    if (!h) return;
    if (h->ins) sqlite3_finalize(h->ins);
    if (h->sel) sqlite3_finalize(h->sel);
    if (h->db)  sqlite3_close(h->db);
    free(h);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nBeginTx(
        JNIEnv *env, jclass cls, jlong handle) {
    Handle *h = j_to_h(handle);
    if (h && h->db) sqlite3_exec(h->db, "BEGIN;", NULL, NULL, NULL);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nCommitTx(
        JNIEnv *env, jclass cls, jlong handle) {
    Handle *h = j_to_h(handle);
    if (h && h->db) sqlite3_exec(h->db, "COMMIT;", NULL, NULL, NULL);
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nAdd(
        JNIEnv *env, jclass cls, jlong handle,
        jlong id, jobject jvecBuf) {
    Handle *h = j_to_h(handle);
    if (!h) return;
    void *vptr = (*env)->GetDirectBufferAddress(env, jvecBuf);
    jlong vlen = (*env)->GetDirectBufferCapacity(env, jvecBuf);

    sqlite3_reset(h->ins);
    sqlite3_clear_bindings(h->ins);
    sqlite3_bind_int64(h->ins, 1, id);
    sqlite3_bind_blob (h->ins, 2, vptr, (int)vlen, SQLITE_TRANSIENT);
    int rc = sqlite3_step(h->ins);
    if (rc != SQLITE_DONE) {
        LOGE("insert step failed: %s", sqlite3_errmsg(h->db));
    }
}

// Returns parallel arrays packed into a single Object[]: [long[] ids, float[] dists].
// Using long[]/float[] (not String[]) avoids the per-row NewStringUTF allocs that
// would otherwise dominate the measured latency.
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nKnn(
        JNIEnv *env, jclass cls, jlong handle,
        jobject jqBuf, jint k) {
    Handle *h = j_to_h(handle);
    if (!h) return NULL;
    void *qptr = (*env)->GetDirectBufferAddress(env, jqBuf);
    jlong qlen = (*env)->GetDirectBufferCapacity(env, jqBuf);

    sqlite3_reset(h->sel);
    sqlite3_clear_bindings(h->sel);
    sqlite3_bind_blob(h->sel, 1, qptr, (int)qlen, SQLITE_TRANSIENT);
    sqlite3_bind_int (h->sel, 2, (int)k);

    jlong  idsTmp [128];
    jfloat distTmp[128];
    int n = 0;
    while (sqlite3_step(h->sel) == SQLITE_ROW && n < 128) {
        idsTmp [n] = sqlite3_column_int64(h->sel, 0);
        distTmp[n] = (jfloat)sqlite3_column_double(h->sel, 1);
        n++;
    }

    jlongArray  jIds   = (*env)->NewLongArray (env, n);
    jfloatArray jDists = (*env)->NewFloatArray(env, n);
    (*env)->SetLongArrayRegion (env, jIds,   0, n, idsTmp);
    (*env)->SetFloatArrayRegion(env, jDists, 0, n, distTmp);

    jclass objCls = (*env)->FindClass(env, "java/lang/Object");
    jobjectArray out = (*env)->NewObjectArray(env, 2, objCls, NULL);
    (*env)->SetObjectArrayElement(env, out, 0, jIds);
    (*env)->SetObjectArrayElement(env, out, 1, jDists);
    return out;
}

// Must be called after bulk insert and before any nKnn. Per SQLiteAI API.md,
// `vector_quantize_scan` operates on a quantized snapshot built by
// `vector_quantize`; without this step the scan returns zero rows (which is
// exactly what we saw: recall=0, sub-100µs latency).
//
// max_memory_mb controls quantize working-set budget; preload toggles
// vector_quantize_preload() to pin the snapshot for cold-start stability.
JNIEXPORT jint JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nFinalizeIndex(
        JNIEnv *env, jclass cls, jlong handle, jint max_memory_mb, jboolean preload) {
    Handle *h = j_to_h(handle);
    if (!h || !h->db) return -1;
    char *err = NULL;
    char sql[128];
    int mm = (int)max_memory_mb;
    if (mm <= 0) mm = 50;
    snprintf(sql, sizeof(sql),
            "SELECT vector_quantize('emb', 'vector', 'max_memory=%dMB');",
            mm);
    int rc = sqlite3_exec(h->db, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        LOGE("vector_quantize failed: %s", err ? err : "(null)");
        sqlite3_free(err);
        return rc;
    }
    if (preload == JNI_TRUE) {
        rc = sqlite3_exec(h->db,
                "SELECT vector_quantize_preload('emb', 'vector');",
                NULL, NULL, &err);
        if (rc != SQLITE_OK) {
            LOGI("vector_quantize_preload skipped: %s", err ? err : "(null)");
            sqlite3_free(err);
        }
    }
    return SQLITE_OK;
}

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_SqliteVectorAiVector_nCount(
        JNIEnv *env, jclass cls, jlong handle) {
    Handle *h = j_to_h(handle);
    if (!h) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(h->db, "SELECT COUNT(*) FROM emb;", -1, &st, NULL)
        != SQLITE_OK) return -1;
    jlong n = -1;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return n;
}
