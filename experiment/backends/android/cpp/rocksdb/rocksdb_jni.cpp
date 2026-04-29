// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/**
 * rocksdb_jni.cpp — Minimal JNI bridge for RocksDB on Android.
 *
 * Exposes a flat key-value API over RocksDB's C++ DB class, enough for
 * the StorageBackend experiment. Column families are used as the equivalent
 * of "named sub-databases" (like LMDB's named DBs or Valkey's key prefixes).
 *
 * RocksDB is an LSM-tree KV store: writes go to an in-memory memtable and
 * are flushed to sorted SST files on disk. Reads check the memtable first,
 * then bloom filters + binary search on SST files. Compaction merges SSTables
 * in the background.
 */

#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>

#include "rocksdb/db.h"
#include "rocksdb/options.h"
#include "rocksdb/slice.h"

#define TAG "RocksDbJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static std::unique_ptr<rocksdb::DB> g_db;

// We use the default column family for simplicity. Keys are prefixed
// with the "db name" to simulate named sub-databases:
// e.g., "readings:r:0000000001" or "stats:count"

extern "C" {

JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativeOpen(
    JNIEnv *env, jclass cls, jstring path) {

    if (g_db) return JNI_TRUE;

    const char *p = env->GetStringUTFChars(path, nullptr);

    rocksdb::Options options;
    options.create_if_missing = true;
    options.compression = rocksdb::kNoCompression;
    options.max_background_jobs = 1;
    options.write_buffer_size = 4 * 1024 * 1024;

    rocksdb::DB* db_raw = nullptr;
    rocksdb::Status s = rocksdb::DB::Open(options, std::string(p), &db_raw);
    env->ReleaseStringUTFChars(path, p);

    if (!s.ok()) {
        LOGE("RocksDB open failed: %s", s.ToString().c_str());
        delete db_raw;
        g_db.reset();
        return JNI_FALSE;
    }
    g_db.reset(db_raw);
    LOGI("RocksDB opened");
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativeClose(JNIEnv *env, jclass cls) {
    g_db.reset();
}

JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativePut(
    JNIEnv *env, jclass cls, jstring key, jstring value) {

    if (!g_db.get()) return JNI_FALSE;

    const char *k = env->GetStringUTFChars(key, nullptr);
    const char *v = env->GetStringUTFChars(value, nullptr);

    rocksdb::Status s = g_db->Put(rocksdb::WriteOptions(), k, v);

    env->ReleaseStringUTFChars(key, k);
    env->ReleaseStringUTFChars(value, v);

    return s.ok() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativeGet(
    JNIEnv *env, jclass cls, jstring key) {

    if (!g_db.get()) return nullptr;

    const char *k = env->GetStringUTFChars(key, nullptr);
    std::string value;
    rocksdb::Status s = g_db->Get(rocksdb::ReadOptions(), k, &value);
    env->ReleaseStringUTFChars(key, k);

    if (!s.ok()) return nullptr;
    return env->NewStringUTF(value.c_str());
}

JNIEXPORT jboolean JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativeDelete(
    JNIEnv *env, jclass cls, jstring key) {

    if (!g_db.get()) return JNI_FALSE;

    const char *k = env->GetStringUTFChars(key, nullptr);
    rocksdb::Status s = g_db->Delete(rocksdb::WriteOptions(), k);
    env->ReleaseStringUTFChars(key, k);

    return s.ok() ? JNI_TRUE : JNI_FALSE;
}

/**
 * Get all keys that start with [prefix], sorted lexicographically.
 * Uses a RocksDB iterator which is efficient for prefix scans.
 */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativeGetKeysWithPrefix(
    JNIEnv *env, jclass cls, jstring prefix) {

    if (!g_db.get()) return nullptr;

    const char *p = env->GetStringUTFChars(prefix, nullptr);
    std::string pfx(p);
    env->ReleaseStringUTFChars(prefix, p);

    std::vector<std::string> keys;
    rocksdb::ReadOptions ro;
    rocksdb::Iterator *it = g_db->NewIterator(ro);

    for (it->Seek(pfx); it->Valid(); it->Next()) {
        std::string k = it->key().ToString();
        if (k.compare(0, pfx.size(), pfx) != 0) break;  // past the prefix
        keys.push_back(k);
    }
    delete it;

    jclass strCls = env->FindClass("java/lang/String");
    jobjectArray out = env->NewObjectArray((jsize)keys.size(), strCls, nullptr);
    for (size_t i = 0; i < keys.size(); i++) {
        jstring js = env->NewStringUTF(keys[i].c_str());
        env->SetObjectArrayElement(out, (jint)i, js);
        env->DeleteLocalRef(js);
    }
    return out;
}

/**
 * Delete all keys with the given prefix. Uses an iterator + batch delete.
 */
JNIEXPORT jint JNICALL
Java_dev_dazzle_experiment_RocksDbBridge_nativeDeleteWithPrefix(
    JNIEnv *env, jclass cls, jstring prefix) {

    if (!g_db.get()) return 0;

    const char *p = env->GetStringUTFChars(prefix, nullptr);
    std::string pfx(p);
    env->ReleaseStringUTFChars(prefix, p);

    rocksdb::WriteBatch batch;
    rocksdb::ReadOptions ro;
    rocksdb::Iterator *it = g_db->NewIterator(ro);
    int count = 0;

    for (it->Seek(pfx); it->Valid(); it->Next()) {
        std::string k = it->key().ToString();
        if (k.compare(0, pfx.size(), pfx) != 0) break;
        batch.Delete(k);
        count++;
    }
    delete it;

    if (count > 0) {
        g_db->Write(rocksdb::WriteOptions(), &batch);
    }
    return (jint)count;
}

} // extern "C"
