// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// rocksdb_ios.h — Flat C surface around RocksDB's stable C API for the
// iOS storage_only benchmark. Mirrors the Android JNI bridge in shape so
// the Swift / Kotlin context managers stay one-to-one comparable.

#ifndef DAZZLE_ROCKSDB_IOS_H
#define DAZZLE_ROCKSDB_IOS_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Open a RocksDB instance at [path]. Returns true on success, false on
/// any failure (the engine prints the underlying status to stderr).
bool rocksdb_ios_open(const char *path);

/// Close the open instance, flushing memtables.
void rocksdb_ios_close(void);

/// Put a UTF-8 key→value pair using default WriteOptions.
bool rocksdb_ios_put(const char *key, const char *value);

/// Get a value by key. Returns malloc'd C string (caller frees) or NULL
/// on missing / error.
char *rocksdb_ios_get(const char *key);

/// Delete a single key. Returns true on success or NotFound.
bool rocksdb_ios_delete(const char *key);

/// Return all keys whose lexicographic prefix matches [prefix], sorted
/// ascending. *out_count receives the size of the returned array; the
/// caller must pass it back to rocksdb_ios_free_keys() to release the
/// per-key + array allocations.
char **rocksdb_ios_get_keys_with_prefix(const char *prefix, size_t *out_count);

/// Atomic delete of every key whose prefix matches [prefix]. Returns the
/// number of keys removed (0 on empty/error).
int rocksdb_ios_delete_with_prefix(const char *prefix);

/// Free an array allocated by rocksdb_ios_get_keys_with_prefix().
void rocksdb_ios_free_keys(char **keys, size_t count);

#ifdef __cplusplus
}
#endif

#endif /* DAZZLE_ROCKSDB_IOS_H */
