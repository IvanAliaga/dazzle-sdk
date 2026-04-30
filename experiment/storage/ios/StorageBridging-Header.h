// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Bridging header for the DazzleStorage app target. Exposes the iOS
// LMDB / ObjectBox / RocksDB C shims to Swift so the storage_only
// benchmark can talk to backends compiled from source without a
// per-backend module map.

#ifndef DAZZLE_STORAGE_BRIDGING_HEADER_H
#define DAZZLE_STORAGE_BRIDGING_HEADER_H

#include "lmdb_ios.h"
#include "rocksdb_ios.h"

#endif
