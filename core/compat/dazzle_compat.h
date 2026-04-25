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

/*
 * dazzle_compat.h — API-shim header for Valkey 8 vs 9 vs 10+
 *
 * The goal of this file is to hide upstream API differences behind stable
 * macros/inlines so that core/transport/dazzle_transport.c (and other in-process
 * bridge code) compiles cleanly against any supported Valkey version.
 *
 * Only the shims that are actually needed by our transport layer live here;
 * we deliberately do NOT try to be a general-purpose compatibility library.
 *
 * Selecting the target version:
 *   - Android: `FetchContent` in sdk/android/src/main/cpp/CMakeLists.txt sets
 *     the tag (default 9.0.3). The build system defines `VALKEY_VERSION_MAJOR`
 *     via -D, which this header keys off.
 *   - iOS: sdk/ios/build.sh clones the selected VALKEY_VERSION and likewise
 *     defines VALKEY_VERSION_MAJOR.
 *
 * TODO: populate this header as `#if` guards are lifted out of dazzle_transport.c.
 *       Known differences so far:
 *         - robj internal pointer access: v8 uses `obj->ptr`, v9 keeps the
 *           same field but hashtable-stored values moved from dict to the
 *           new hashtable API (listpack unchanged).
 *         - `createClient(CLIENT_ID_*)` signature grew a flags arg in v9.
 *         - module loading path: v8 had `modules/lua/`, v9 integrates Lua.
 *       When a specific shim is extracted from dazzle_transport.c, add it here
 *       and remove the inline #if from the .c file.
 */
#ifndef DAZZLE_COMPAT_H
#define DAZZLE_COMPAT_H

#ifndef VALKEY_VERSION_MAJOR
/* Default to v9 when the build system did not pin a version. */
#define VALKEY_VERSION_MAJOR 9
#endif

#if VALKEY_VERSION_MAJOR < 8 || VALKEY_VERSION_MAJOR > 10
#error "Unsupported Valkey major version — see core/compat/dazzle_compat.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Placeholder section — real shims land here as they are extracted from
 * core/transport/dazzle_transport.c. Keep each one small, well-commented, and
 * scoped to a single upstream API surface. */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* DAZZLE_COMPAT_H */
