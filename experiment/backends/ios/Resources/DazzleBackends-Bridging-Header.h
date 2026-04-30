// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Bridging header for the iOS DazzleBackends app target. Exposes the
// sqlite-vec C shim to Swift so the vector-bench backend can talk to
// SQLite + sqlite-vec without a module map.

#ifndef DAZZLEBACKENDS_BRIDGING_HEADER_H
#define DAZZLEBACKENDS_BRIDGING_HEADER_H

#include "sqlitevec_ios.h"
#include "svai_ios.h"

#endif
