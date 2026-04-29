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
 * JNI bridge to LMDB compiled from source (mdb.c + midl.c).
 *
 * LMDB is a memory-mapped B+tree KV store from OpenLDAP. Zero-copy reads,
 * single-writer/multi-reader, crash-safe via copy-on-write. The entire
 * library is 2 C files and compiles for any platform the NDK targets.
 */
object LmdbBridge {
    init {
        System.loadLibrary("lmdb-jni")
    }

    /** Open the LMDB environment at [path]. Creates the directory if needed. */
    external fun nativeOpen(path: String, maxDbs: Int, mapSizeMB: Int): Boolean

    /** Close the environment. */
    external fun nativeClose()

    /**
     * Flush dirty mmap pages to disk so a subsequent stat() reports
     * accurate `st_blocks`. The env is opened with MDB_NOSYNC|MDB_WRITEMAP
     * for ingest speed, so disk allocation is deferred until this call.
     */
    external fun nativeSync(force: Boolean): Boolean

    /** Put a key-value pair into the named sub-database. */
    external fun nativePut(dbName: String?, key: String, value: String): Boolean

    /** Get a value by key from the named sub-database. Null if not found. */
    external fun nativeGet(dbName: String?, key: String): String?

    /** Delete a key from the named sub-database. */
    external fun nativeDelete(dbName: String?, key: String): Boolean

    /** Drop (empty) all entries in the named sub-database. */
    external fun nativeDrop(dbName: String?): Boolean

    /** Get all keys in the named sub-database, sorted by key. */
    external fun nativeGetAllKeys(dbName: String?): Array<String>?
}
