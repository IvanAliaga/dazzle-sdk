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

#ifndef VALKEY_IOS_H
#define VALKEY_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

/// Start the embedded Valkey server in a background thread, with a custom
/// CLI argv built by the Swift layer from a DazzleConfig. argv[0] must be
/// the program name (conventionally "valkey-server"), argv[argc] must be
/// NULL. The server spawns a background thread that calls valkey_main()
/// with this argv.
/// @return 1 on success, 0 on failure (inspect <data_dir>/valkey.log).
int dazzle_ios_start_argv(int argc, const char **argv);

/// Legacy entry point kept for backward compatibility with existing
/// consumers that still call the three-parameter variant. Internally it
/// builds a default DazzleConfig-equivalent argv and delegates to
/// dazzle_ios_start_argv(). New callers should use dazzle_ios_start_argv().
int dazzle_ios_start(const char *data_dir, int port, const char *max_memory);

/// Gracefully stop the server via SHUTDOWN command.
/// Safe to call from any thread.
void dazzle_ios_stop(int port);

/// Check if the server is currently running.
/// @return 1 if running, 0 if stopped
int dazzle_ios_is_running(void);

/// Execute a Valkey command directly in-process (bypasses TCP loopback).
/// @param argc Number of arguments (command name + args)
/// @param argv Array of C strings: argv[0] is the command name
/// @return Heap-allocated RESP response string; caller must pass to valkey_direct_free()
///         Returns NULL if the direct path is unavailable or argc <= 0
char *valkey_direct_command(int argc, const char **argv);

/// Free a response returned by valkey_direct_command() or valkey_direct_read().
void valkey_direct_free(char *result);

/// Phase 1 direct-read path — answer HMGET from the snapshot cache without
/// going through the event-loop pipe. Target latency ~10–50 µs on iOS vs
/// ~200–400 µs via the pipe.
/// @param argc Number of arguments; must be 3 or more
/// @param argv argv[0] must be "HMGET", argv[1] the key, argv[2..] fields
/// @return Heap-allocated RESP array string on cache hit (caller frees with
///         valkey_direct_free); NULL on miss (caller should fall back to the
///         pipe path via valkey_direct_command)
char *valkey_direct_read(int argc, const char **argv);

/// Phase 5 typed direct-read — same semantics as valkey_direct_read but
/// returns pre-split values, skipping the RESP serialise + parse round-trip.
/// On iOS this removes ~30–80 µs of string work per call.
/// @param key The hash key (e.g. "sensor:stats")
/// @param nfields Number of fields in the array
/// @param fields NUL-terminated field names
/// @param out Output array of at least nfields slots. On hit each out[i]
///            is either a malloc'd string (caller frees with
///            valkey_direct_free) or NULL when that field is absent.
/// @return 1 on cache hit, 0 on miss (caller should fall back to the pipe
///         path). On miss out[] is left untouched.
int valkey_direct_read_fields(const char *key, int nfields,
                              const char **fields, char **out);

/// Phase 7 typed HGETALL — iterate every field stored for `key` in the
/// snapshot cache without generating or parsing any RESP. Lets
/// ContextStore.get() bypass the HGETALL-through-RESP path that
/// regressed vs the pre-refactor baseline.
/// @param key The hash key
/// @param out_fields caller-allocated capacity max_pairs; each
///        populated slot is a malloc'd NUL-terminated string (caller
///        frees with valkey_direct_free)
/// @param out_values idem
/// @param max_pairs upper bound on how many pairs to emit
/// @return >=0 number of pairs written; -1 on snapshot miss (caller
///         should fall back to the pipe path)
int dazzle_snapshot_hgetall_typed(const char *key,
                                  char      **out_fields,
                                  char      **out_values,
                                  int         max_pairs);

/// Phase 2 — typed SMEMBERS. Returns set members stored in the
/// snapshot cache. Every populated slot is a malloc'd C string; caller
/// frees each with `valkey_direct_free`. Returns -1 on snapshot miss
/// or wrong type.
int dazzle_snapshot_smembers_typed(const char *key,
                                   char      **out_members,
                                   int         max_members);

/// Phase 2 — typed ZRANGE (no WITHSCORES). Emits every member in
/// insertion order (not score order — use zrange_by_score_typed for
/// score-ordered output). Returns -1 on snapshot miss / wrong type.
int dazzle_snapshot_zrange_all_typed(const char *key,
                                     char      **out_members,
                                     int         max_members);

/// Phase 2 — typed ZRANGEBYSCORE. Returns members whose stored score
/// is in `[min_score, max_score]`, sorted ascending by score. -1 on
/// snapshot miss / wrong type.
int dazzle_snapshot_zrange_by_score_typed(const char *key,
                                          double      min_score,
                                          double      max_score,
                                          char      **out_members,
                                          int         max_members);

/// Phase 2 — typed GET for string keys. Writes the value into `out`
/// (at most `cap` bytes, NUL-terminated) and returns the length in
/// bytes. -1 on snapshot miss / wrong type.
int dazzle_snapshot_get_string_typed(const char *key,
                                     char       *out,
                                     int         cap);

/// Phase 6a multi-key snapshot HMGET — answers N HMGETs from the snapshot
/// cache under a single rwlock, amortising FFI + lock acquisition across
/// the batch.  See dazzle_snapshot_mhmget in dazzle_transport.c.
/// @param nkeys        Number of keys in the batch.
/// @param keys         nkeys NUL-terminated key strings.
/// @param field_counts nkeys ints; field_counts[k] is the number of fields
///                     requested for keys[k].
/// @param fields       Flat array of sum(field_counts) NUL-terminated field
///                     names in the same order as keys.
/// @param out          Output array of sum(field_counts) slots, zeroed on
///                     entry.  On snapshot hit each slot is either a
///                     malloc'd string (caller frees via valkey_direct_free)
///                     or NULL when that field is absent.  Slots for keys
///                     that missed the snapshot stay NULL.
/// @return 1 if at least one key hit the snapshot, 0 if all missed.
int valkey_direct_read_mfields(int nkeys,
                               const char *const *keys,
                               const int *field_counts,
                               const char **fields,
                               char **out);

/// Plan 08 ablation — re-read DAZZLE_DISABLE_SNAPSHOT and
/// DAZZLE_SNAPSHOT_BUCKETS into transport-layer atomics so sweep harnesses
/// can flip them mid-run without a process restart.  Idempotent; safe to
/// call from any thread.  dazzle_direct_init() invokes this on every fresh
/// server start, so single-configuration benchmarks need not call it.
void valkey_snapshot_reload_config(void);

/// Phase 6b coalesced write pipeline — dispatches N commands across the
/// in-process transport in a single FFI crossing.  On iOS this takes the
/// server mutex once, writes N request pointers to the event-loop pipe,
/// and waits for all of them with a single cond_wait loop.
/// @param n         Number of commands.
/// @param argv_lens n ints; argv_lens[i] is the argc of command i.
/// @param argv_flat Flat array of sum(argv_lens) NUL-terminated C strings
///                  in the same order as the commands.
/// @param replies   n output slots; replies[i] receives a heap-allocated
///                  RESP string on success (caller frees via
///                  valkey_direct_free) or NULL on failure.
/// @return 1 on dispatch, 0 if the transport is not initialised.
int valkey_pipeline_args(int n,
                         const int *argv_lens,
                         const char **argv_flat,
                         char **replies);

#ifdef __cplusplus
}
#endif

#endif
