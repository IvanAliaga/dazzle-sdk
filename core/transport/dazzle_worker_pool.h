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

/* dazzle_worker_pool.h — Parallel read execution pool (Plan 02).
 *
 * Exposes a minimal worker-pool API that lets read-only commands run on
 * background pthreads instead of the single Valkey event loop. The design
 * mirrors valkey-io/valkey#2208 (per-slot queues + sticky dispatch) adapted
 * to Dazzle's embedded model.
 *
 * Lifecycle
 * =========
 *   main thread (server startup)                worker threads
 *   ----------------------------                -----------------
 *   dazzle_direct_init()
 *     └─ dwp_init()                             created, blocked on cv
 *                                                  waiting for jobs
 *   directCommandHandler()
 *     └─ classify request
 *         └─ dwp_enqueue(req)                   wake, pop, exec call(),
 *                                                  signal req->done
 *
 * Flag gating
 * ===========
 * Controlled by env var DAZZLE_PARALLEL_READS (default: "0"). When 0,
 * dwp_init() still creates workers (shadow mode: useful to catch build /
 * pthread_create regressions), but dwp_enabled() returns 0 so the
 * dispatcher never hands work over — every request flows through the
 * existing single-thread path. Flip to 1 only once the upstream
 * thread-local-client patch (versions/v9/patches/04_threading.patch)
 * is applied and validated; see the header comment in dazzle_worker_pool.c
 * for the exact prerequisites.
 *
 * Thread count
 * ============
 * DAZZLE_WORKER_THREADS overrides the default. Default picks
 *     min(4, hardware_concurrency() - 1)
 * capped at DWP_MAX_WORKERS. Workers are sticky per slot: a request whose
 * first key hashes to slot S always goes to worker[S % N_workers]. This
 * preserves L1 cache locality (gap raised by @zuiderkwast on the upstream
 * issue).
 */

#ifndef DAZZLE_WORKER_POOL_H
#define DAZZLE_WORKER_POOL_H

#if defined(VALKEY_IOS) || defined(__ANDROID__)

#include <stdint.h>

/* Forward declaration to avoid pulling server.h from this header. The real
 * DirectRequest struct lives in dazzle_transport.c; only the pool internals
 * and the dispatcher ever deref it. */
struct DirectRequest;

/* Hard cap on worker count; matches the cluster slot count's logical
 * top-of-range and keeps the per-slot dispatch modulo cheap.  Raising this
 * requires only bumping the compile-time constant. */
#define DWP_MAX_WORKERS 8
#define DWP_SLOTS       16384

#ifdef __cplusplus
extern "C" {
#endif

/* Initialise the pool.  Called once from dazzle_direct_init() on the server
 * thread right after the event loop file event is registered.  Idempotent.
 * Returns 0 on success (workers spawned), -1 on pthread_create failure
 * (caller should keep running with parallel reads disabled). */
int dwp_init(void);

/* Tear down the pool.  Not wired from anywhere today — the embedded server
 * lives for the whole process lifetime — but exposed for future use (unit
 * tests, clean shutdown).  Safe to call before or after init. */
void dwp_shutdown(void);

/* 1 if dispatch is enabled (flag on AND pool initialised), 0 otherwise.
 * Cheap atomic read; safe from the event-loop thread. */
int dwp_enabled(void);

/* Push a request onto the worker queue selected by the first-key hash.
 * Caller (directCommandHandler) must have already verified the command is
 * safe to offload (see dazzle_slot_safe.h).  The worker decides whether to
 * take the slot's rdlock (read) or wrlock (write) based on the command name.
 *
 * Returns 0 on success (worker will signal req->done when finished); -1 if
 * the target queue is full and the caller should fall back to executing
 * inline on the main thread.
 *
 * argv / argc are borrowed for the duration of the call; ownership stays
 * with the caller.  The worker builds its own robj** from the C strings. */
int dwp_enqueue(struct DirectRequest *req);

/* Per-slot striped rwlock.  Readers (GET/HGET/...) take rdlock; writers
 * (HSET/HINCRBY/XADD/...) take wrlock.  Same lock is used by the main
 * event-loop thread and by every worker, so parallel reads stay parallel
 * while writes on the same slot serialize against in-flight reads.
 *
 * Striping collapses DWP_SLOTS (16384) into DWP_LOCK_STRIPES (64) real
 * pthread_rwlock_t objects; collisions cost a bit of cross-slot contention
 * but are negligible in practice and save 16k lock initializers. */
void dwp_slot_rdlock(uint32_t slot);
void dwp_slot_wrlock(uint32_t slot);
void dwp_slot_unlock(uint32_t slot);

/* Global read/write barrier.  Every worker execution wraps its slot lock
 * inside a dwp_global_rdlock/unlock pair; the main-thread path does the
 * same for commands on the slot-safe whitelist.  Commands *not* on the
 * whitelist (EVAL / EVALSHA / DEBUG / anything whose keyspace footprint
 * we cannot infer from argv[1]) take dwp_global_wrlock INSTEAD of a slot
 * lock, which excludes every worker for the duration of the call.
 *
 * Why: req->slot is derived from argv[1] unconditionally.  For EVAL /
 * EVALSHA that argument is the script body / SHA, not a key — so slot
 * locking gives no protection between Lua-script writes into e.g.
 * `sensor:stats` and a worker HMGET on the same key via a different
 * stripe.  The global barrier closes that hole without needing a
 * command-aware multi-key lock acquisition (which would require
 * careful lock-ordering to avoid deadlocks). */
void dwp_global_rdlock(void);
void dwp_global_wrlock(void);
void dwp_global_unlock(void);

/* Compute the slot for a key.  Wraps Valkey's keyHashSlot but keeps the
 * pool self-contained (no include of cluster_legacy.h from callers). */
uint32_t dwp_key_slot(const char *key, int keylen);

/* Plan 09 — key-aware locking for EVAL / EVALSHA.  Takes wrlocks on every
 * unique stripe derived from a list of keys, in ascending stripe order
 * (deadlock-safe) with dedup so the caller never self-deadlocks on keys
 * that share a stripe.  The caller is responsible for:
 *   - taking dwp_global_rdlock() FIRST (consistent with the slot-lock path)
 *   - calling dwp_multi_slot_unlock with the same array when the script
 *     completes (the function reverses the order internally)
 *
 * Returns the number of unique stripes locked (0 ≤ n_locked ≤ nkeys). The
 * caller must pass the same array (slots[], n_locked) to
 * dwp_multi_slot_unlock; the array is rewritten in place with the unique
 * sorted stripe indices actually locked. */
int  dwp_multi_slot_wrlock(uint32_t *slots, int nkeys);
void dwp_multi_slot_unlock(const uint32_t *unique_slots, int n_locked);

/* 1 if DAZZLE_EVAL_KEY_LOCKS is in effect (default on; set to "0" to force
 * the legacy global_wrlock path for EVAL / EVALSHA).  Cheap atomic read. */
int  dwp_eval_key_locks_enabled(void);

/* Number of workers actually spawned (0 if dwp_init failed or not called). */
int dwp_worker_count(void);

#ifdef __cplusplus
}
#endif

#endif /* VALKEY_IOS || __ANDROID__ */

#endif /* DAZZLE_WORKER_POOL_H */
