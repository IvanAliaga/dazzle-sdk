// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// lmdb_ios.h — Public surface for the iOS LMDB shim.
//
// Wraps the OpenLDAP LMDB C API (mdb.c + midl.c) behind a flat C interface
// that mirrors the Kotlin LmdbBridge object on Android. The Swift side
// imports these symbols via the storage app's bridging header and uses
// them from LmdbContextManager.swift.

#ifndef DAZZLE_LMDB_IOS_H
#define DAZZLE_LMDB_IOS_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Open the LMDB environment at [path]. Returns true on success.
bool lmdb_ios_open(const char *path, int max_dbs, int map_size_mb);

/// Close the environment if open.
void lmdb_ios_close(void);

/// Force a sync of dirty mmap pages so st_blocks reflects the dataset.
bool lmdb_ios_sync(bool force);

/// Put key→value into [db_name]. Pass NULL for the unnamed default DB.
bool lmdb_ios_put(const char *db_name, const char *key, const char *value);

/// Get a value by key. Returns malloc'd C string (caller frees) or NULL.
char *lmdb_ios_get(const char *db_name, const char *key);

/// Delete a key. Returns true if removed or not found.
bool lmdb_ios_delete(const char *db_name, const char *key);

/// Drop all entries from a sub-database (DB itself stays).
bool lmdb_ios_drop(const char *db_name);

/// Get all keys in [db_name], sorted. Caller frees each entry and the array.
/// out_count is set to the number of keys returned (0 on empty/error).
char **lmdb_ios_get_all_keys(const char *db_name, size_t *out_count);

/// Free an array allocated by lmdb_ios_get_all_keys.
void lmdb_ios_free_keys(char **keys, size_t count);

#ifdef __cplusplus
}
#endif

#endif /* DAZZLE_LMDB_IOS_H */
