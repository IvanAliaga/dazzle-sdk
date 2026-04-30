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

/**
 * lmdb_jni.c — Minimal JNI bridge for LMDB on Android.
 *
 * Exposes just enough of the LMDB C API for the StorageBackend experiment:
 * open/close env, put/get/delete, cursor iteration. All operations are
 * synchronous and map 1:1 to LMDB's transaction-wrapped calls.
 *
 * LMDB is a B+tree memory-mapped KV store: reads are zero-copy (the
 * returned pointer is directly into the mmap region), writes go through
 * a copy-on-write mechanism. A single LMDB env can hold multiple named
 * databases (sub-DBs) within one file.
 */

#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <android/log.h>
#include "lmdb.h"

#define TAG "LmdbJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* We keep ONE env open for the lifetime of the process. */
static MDB_env *g_env = NULL;

/* ------------------------------------------------------------------
 * open(path, maxDbs, mapSizeMB) → boolean
 * ------------------------------------------------------------------ */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeOpen(
    JNIEnv *env, jclass cls, jstring path, jint maxDbs, jint mapSizeMB) {

    if (g_env) return JNI_TRUE;  /* already open */

    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    int rc = mdb_env_create(&g_env);
    if (rc) { LOGE("mdb_env_create: %s", mdb_strerror(rc)); goto fail; }

    mdb_env_set_maxdbs(g_env, (MDB_dbi)maxDbs);
    mdb_env_set_mapsize(g_env, (size_t)mapSizeMB * 1024UL * 1024UL);

    rc = mdb_env_open(g_env, p, MDB_NOSYNC | MDB_WRITEMAP, 0664);
    if (rc) { LOGE("mdb_env_open(%s): %s", p, mdb_strerror(rc)); goto fail; }

    (*env)->ReleaseStringUTFChars(env, path, p);
    LOGI("LMDB open at %s, map=%dMB, maxDbs=%d", p, mapSizeMB, maxDbs);
    return JNI_TRUE;

fail:
    (*env)->ReleaseStringUTFChars(env, path, p);
    if (g_env) { mdb_env_close(g_env); g_env = NULL; }
    return JNI_FALSE;
}

/* ------------------------------------------------------------------
 * close()
 * ------------------------------------------------------------------ */
JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeClose(JNIEnv *env, jclass cls) {
    if (g_env) { mdb_env_close(g_env); g_env = NULL; }
}

/* ------------------------------------------------------------------
 * sync(force) — flush dirty mmap pages to disk so st_blocks is accurate.
 *
 * The env was opened with MDB_NOSYNC | MDB_WRITEMAP for ingest speed,
 * so writes only land in the mmap region; the kernel hasn't allocated
 * disk blocks until something forces a flush. Without this call,
 * Os.stat().st_blocks reports 0 and footprint accounting under-reports
 * by the entire dataset.
 * ------------------------------------------------------------------ */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeSync(
    JNIEnv *env, jclass cls, jboolean force) {
    if (!g_env) return JNI_FALSE;
    int rc = mdb_env_sync(g_env, force ? 1 : 0);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

/* ------------------------------------------------------------------
 * put(dbName, key, value) → boolean
 * ------------------------------------------------------------------ */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativePut(
    JNIEnv *env, jclass cls, jstring dbName, jstring key, jstring value) {

    if (!g_env) return JNI_FALSE;

    const char *db = dbName ? (*env)->GetStringUTFChars(env, dbName, NULL) : NULL;
    const char *k  = (*env)->GetStringUTFChars(env, key, NULL);
    const char *v  = (*env)->GetStringUTFChars(env, value, NULL);

    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, 0, &txn);
    if (rc) goto done;

    rc = mdb_dbi_open(txn, db, MDB_CREATE, &dbi);
    if (rc) { mdb_txn_abort(txn); goto done; }

    MDB_val mk = { .mv_size = strlen(k), .mv_data = (void *)k };
    MDB_val mv = { .mv_size = strlen(v), .mv_data = (void *)v };
    rc = mdb_put(txn, dbi, &mk, &mv, 0);
    if (rc) { mdb_txn_abort(txn); goto done; }

    rc = mdb_txn_commit(txn);

done:
    if (db) (*env)->ReleaseStringUTFChars(env, dbName, db);
    (*env)->ReleaseStringUTFChars(env, key, k);
    (*env)->ReleaseStringUTFChars(env, value, v);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

/* ------------------------------------------------------------------
 * get(dbName, key) → String or null
 * ------------------------------------------------------------------ */
JNIEXPORT jstring JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeGet(
    JNIEnv *env, jclass cls, jstring dbName, jstring key) {

    if (!g_env) return NULL;

    const char *db = dbName ? (*env)->GetStringUTFChars(env, dbName, NULL) : NULL;
    const char *k  = (*env)->GetStringUTFChars(env, key, NULL);
    jstring result = NULL;

    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, MDB_RDONLY, &txn);
    if (rc) goto done;

    rc = mdb_dbi_open(txn, db, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); goto done; }

    MDB_val mk = { .mv_size = strlen(k), .mv_data = (void *)k };
    MDB_val mv;
    rc = mdb_get(txn, dbi, &mk, &mv);
    if (rc == 0) {
        /* mv.mv_data is NOT null-terminated, create a temp copy */
        char *tmp = malloc(mv.mv_size + 1);
        memcpy(tmp, mv.mv_data, mv.mv_size);
        tmp[mv.mv_size] = '\0';
        result = (*env)->NewStringUTF(env, tmp);
        free(tmp);
    }

    mdb_txn_abort(txn);  /* read-only txn, just abort to release */

done:
    if (db) (*env)->ReleaseStringUTFChars(env, dbName, db);
    (*env)->ReleaseStringUTFChars(env, key, k);
    return result;
}

/* ------------------------------------------------------------------
 * delete(dbName, key) → boolean
 * ------------------------------------------------------------------ */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeDelete(
    JNIEnv *env, jclass cls, jstring dbName, jstring key) {

    if (!g_env) return JNI_FALSE;

    const char *db = dbName ? (*env)->GetStringUTFChars(env, dbName, NULL) : NULL;
    const char *k  = (*env)->GetStringUTFChars(env, key, NULL);

    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, 0, &txn);
    if (rc) goto done;

    rc = mdb_dbi_open(txn, db, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); goto done; }

    MDB_val mk = { .mv_size = strlen(k), .mv_data = (void *)k };
    rc = mdb_del(txn, dbi, &mk, NULL);
    if (rc && rc != MDB_NOTFOUND) { mdb_txn_abort(txn); goto done; }

    rc = mdb_txn_commit(txn);

done:
    if (db) (*env)->ReleaseStringUTFChars(env, dbName, db);
    (*env)->ReleaseStringUTFChars(env, key, k);
    return (rc == 0 || rc == MDB_NOTFOUND) ? JNI_TRUE : JNI_FALSE;
}

/* ------------------------------------------------------------------
 * drop(dbName) — delete all entries in the named sub-database
 * ------------------------------------------------------------------ */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeDrop(
    JNIEnv *env, jclass cls, jstring dbName) {

    if (!g_env) return JNI_FALSE;

    const char *db = dbName ? (*env)->GetStringUTFChars(env, dbName, NULL) : NULL;

    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    int rc = mdb_txn_begin(g_env, NULL, 0, &txn);
    if (rc) goto done;

    rc = mdb_dbi_open(txn, db, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); goto done; }

    rc = mdb_drop(txn, dbi, 0);  /* 0 = empty the DB, don't delete it */
    if (rc) { mdb_txn_abort(txn); goto done; }

    rc = mdb_txn_commit(txn);

done:
    if (db) (*env)->ReleaseStringUTFChars(env, dbName, db);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

/* ------------------------------------------------------------------
 * getAllKeys(dbName) → String[] (all keys in the sub-DB, sorted)
 * ------------------------------------------------------------------ */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_experiment_LmdbBridge_nativeGetAllKeys(
    JNIEnv *env, jclass cls, jstring dbName) {

    if (!g_env) return NULL;

    const char *db = dbName ? (*env)->GetStringUTFChars(env, dbName, NULL) : NULL;

    MDB_txn *txn = NULL;
    MDB_dbi dbi;
    MDB_cursor *cursor = NULL;
    int rc = mdb_txn_begin(g_env, NULL, MDB_RDONLY, &txn);
    if (rc) { if (db) (*env)->ReleaseStringUTFChars(env, dbName, db); return NULL; }

    rc = mdb_dbi_open(txn, db, 0, &dbi);
    if (rc) { mdb_txn_abort(txn); if (db) (*env)->ReleaseStringUTFChars(env, dbName, db); return NULL; }

    /* First pass: count entries */
    MDB_stat stat;
    mdb_stat(txn, dbi, &stat);
    size_t count = stat.ms_entries;

    /* Allocate Java String array */
    jclass strCls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray out = (*env)->NewObjectArray(env, (jsize)count, strCls, NULL);

    rc = mdb_cursor_open(txn, dbi, &cursor);
    if (rc) { mdb_txn_abort(txn); if (db) (*env)->ReleaseStringUTFChars(env, dbName, db); return out; }

    MDB_val mk, mv;
    int idx = 0;
    while (mdb_cursor_get(cursor, &mk, &mv, idx == 0 ? MDB_FIRST : MDB_NEXT) == 0) {
        char *tmp = malloc(mk.mv_size + 1);
        memcpy(tmp, mk.mv_data, mk.mv_size);
        tmp[mk.mv_size] = '\0';
        jstring js = (*env)->NewStringUTF(env, tmp);
        (*env)->SetObjectArrayElement(env, out, idx, js);
        (*env)->DeleteLocalRef(env, js);
        free(tmp);
        idx++;
    }

    mdb_cursor_close(cursor);
    mdb_txn_abort(txn);
    if (db) (*env)->ReleaseStringUTFChars(env, dbName, db);
    return out;
}
