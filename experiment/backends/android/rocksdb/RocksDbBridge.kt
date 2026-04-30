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

package dev.dazzle.experiment

/**
 * JNI bridge to RocksDB compiled from source via NDK.
 *
 * RocksDB is Facebook/Meta's LSM-tree embedded KV store. Keys are
 * byte-sorted; writes go to an in-memory memtable and flush to SST
 * files on disk. Reads use bloom filters + binary search.
 *
 * We use key prefixes to simulate named sub-databases:
 *   "readings:" + sequential_id
 *   "stats:" + field_name
 *   "anomalies:" + minute_string
 *   "decisions:" + cp_index
 *   "checkpoints:" + cp_index
 */
object RocksDbBridge {
    init {
        System.loadLibrary("rocksdb-jni")
    }

    external fun nativeOpen(path: String): Boolean
    external fun nativeClose()
    external fun nativePut(key: String, value: String): Boolean
    external fun nativeGet(key: String): String?
    external fun nativeDelete(key: String): Boolean
    external fun nativeGetKeysWithPrefix(prefix: String): Array<String>?
    external fun nativeDeleteWithPrefix(prefix: String): Int
}
