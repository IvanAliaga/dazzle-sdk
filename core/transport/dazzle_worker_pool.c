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

/* dazzle_worker_pool.c — see dazzle_worker_pool.h for the high-level design.
 *
 * Upstream prerequisite
 * =====================
 * This file compiles and links standalone, but dwp_enabled() returns 0
 * unless DAZZLE_PARALLEL_READS=1 AND the upstream thread-safety patch is
 * applied (versions/v9/patches/04_threading.patch, tracked as .TODO until
 * Plan 02 M1 lands it).  That patch:
 *
 *   - Moves `server.current_client` / `server.executing_client` to
 *     __thread storage so each worker has its own.
 *   - Adds a `BLOCKED_SLOT` client state for the write-barrier drain phase.
 *   - Guards `kvstore` slot reads with a reentrant path.
 *
 * Without it, worker threads that call() would clobber the main thread's
 * current_client and the server would crash under load.  The pool stays in
 * shadow mode (workers spawned, idle) to validate that pthread_create()
 * works inside the embedded process on both iOS (QoS + thread limits) and
 * Android (SECCOMP filter).  Shadow-mode smoke: boot the demo app, inspect
 * `ps -T` (Android) or Instruments (iOS); you should see N extra threads
 * named "dazzle-wN" that stay blocked on their condvar.
 */

#if defined(VALKEY_IOS) || defined(__ANDROID__)

#include "dazzle_worker_pool.h"

/* Valkey internals.  server.h brings in client / robj / call() / serverLog. */
#include "server.h"
#include "cluster.h"   /* keyHashSlot */

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

/* Forward: defined in dazzle_transport.c; kept opaque via dwp_request_* helpers
 * so this file does not have to duplicate the struct layout. */
struct DirectRequest;
extern int   dwp_request_argc(const struct DirectRequest *req);
extern const char **dwp_request_argv(const struct DirectRequest *req);
extern void  dwp_request_set_result(struct DirectRequest *req, char *result);
extern void  dwp_request_signal_done(struct DirectRequest *req);
extern uint32_t dwp_request_slot(const struct DirectRequest *req);

/* Hook exported by dazzle_transport.c so workers that handle writes can
 * update the HMGET snapshot cache exactly like the main event loop would.
 * Called with the command already executed and its raw RESP reply available. */
extern void  dazzle_snapshot_mirror_write(int argc, const char *const *argv,
                                          const char *reply);

/* Read/write classifier exported from dazzle_slot_safe.h, used by the worker
 * to decide rdlock vs. wrlock without pulling the header twice. */
#include "dazzle_slot_safe.h"

/* ── Tunables ───────────────────────────────────────────────────────────── */

#define DWP_QUEUE_SIZE      256   /* power-of-2; per-worker ring capacity */
#define DWP_QUEUE_MASK      (DWP_QUEUE_SIZE - 1)

/* 64 striped rwlocks collapse DWP_SLOTS keyspace slots into a tractable
 * number of real locks.  At 6 concurrent agents on the bench the collision
 * rate is negligible; raise if an uncontended benchmark stops scaling. */
#define DWP_LOCK_STRIPES    64
#define DWP_LOCK_MASK       (DWP_LOCK_STRIPES - 1)

static pthread_rwlock_t s_slot_locks[DWP_LOCK_STRIPES];
static int              s_slot_locks_initialized = 0;

/* Global barrier — see dwp_worker_pool.h for the rationale.  Protects
 * against non-whitelisted main-thread commands whose keyspace footprint
 * cannot be captured by the argv[1] slot computation.  Initialised in
 * dwp_init() alongside the per-slot stripes. */
static pthread_rwlock_t s_global_barrier;
static int              s_global_barrier_initialized = 0;

static inline pthread_rwlock_t *slot_lock(uint32_t slot) {
    return &s_slot_locks[slot & DWP_LOCK_MASK];
}

void dwp_slot_rdlock(uint32_t slot) {
    if (!s_slot_locks_initialized) return;
    pthread_rwlock_rdlock(slot_lock(slot));
}

void dwp_slot_wrlock(uint32_t slot) {
    if (!s_slot_locks_initialized) return;
    pthread_rwlock_wrlock(slot_lock(slot));
}

void dwp_slot_unlock(uint32_t slot) {
    if (!s_slot_locks_initialized) return;
    pthread_rwlock_unlock(slot_lock(slot));
}

void dwp_global_rdlock(void) {
    if (!s_global_barrier_initialized) return;
    pthread_rwlock_rdlock(&s_global_barrier);
}

void dwp_global_wrlock(void) {
    if (!s_global_barrier_initialized) return;
    pthread_rwlock_wrlock(&s_global_barrier);
}

void dwp_global_unlock(void) {
    if (!s_global_barrier_initialized) return;
    pthread_rwlock_unlock(&s_global_barrier);
}

/* ── Plan 09: multi-stripe wrlock for EVAL / EVALSHA ─────────────────────
 * Replaces the nuclear global_wrlock with fine-grained locks on exactly
 * the stripes the Lua script declared via its KEYS array. Correctness
 * rests on the Redis/Valkey convention that scripts only access keys
 * declared in KEYS — which the Dazzle backends follow. An escape hatch
 * (DAZZLE_EVAL_KEY_LOCKS=0) restores the legacy global_wrlock path.
 *
 * Lock ordering: sorted ascending by stripe index, deadlock-free against
 * any other call that follows the same discipline. Duplicates (multiple
 * keys hashing to the same stripe) are collapsed so we never self-
 * deadlock on a recursive wrlock. */

static atomic_int s_eval_key_locks = 1;   /* default on; flipped by env */

static void reload_eval_key_locks_flag(void) {
    const char *env = getenv("DAZZLE_EVAL_KEY_LOCKS");
    int v = (env && env[0] == '0' && env[1] == '\0') ? 0 : 1;
    atomic_store_explicit(&s_eval_key_locks, v, memory_order_release);
}

int dwp_eval_key_locks_enabled(void) {
    return atomic_load_explicit(&s_eval_key_locks, memory_order_acquire);
}

static int cmp_uint32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a;
    uint32_t y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

int dwp_multi_slot_wrlock(uint32_t *slots, int nkeys) {
    if (!s_slot_locks_initialized || !slots || nkeys <= 0) return 0;

    /* Dedupe by (slot & DWP_LOCK_MASK) so we lock each real rwlock at
     * most once.  Using the mask directly means keys that share a stripe
     * collapse to one lock acquisition — important because recursive
     * wrlock on the same rwlock is undefined on POSIX. */
    for (int i = 0; i < nkeys; i++) slots[i] &= DWP_LOCK_MASK;
    qsort(slots, (size_t)nkeys, sizeof(uint32_t), cmp_uint32);

    int n_unique = 0;
    for (int i = 0; i < nkeys; i++) {
        if (n_unique == 0 || slots[n_unique - 1] != slots[i])
            slots[n_unique++] = slots[i];
    }

    /* Acquire in sorted order — any two callers following this discipline
     * will take locks in a consistent global order, so no deadlock. */
    for (int i = 0; i < n_unique; i++)
        pthread_rwlock_wrlock(&s_slot_locks[slots[i]]);

    return n_unique;
}

void dwp_multi_slot_unlock(const uint32_t *unique_slots, int n_locked) {
    if (!s_slot_locks_initialized || !unique_slots) return;
    /* Reverse order for symmetry; correctness doesn't require it because
     * unlock is non-blocking, but it mirrors conventional lock hygiene. */
    for (int i = n_locked - 1; i >= 0; i--)
        pthread_rwlock_unlock(&s_slot_locks[unique_slots[i]]);
}

/* ── Per-worker state ───────────────────────────────────────────────────── */

typedef struct worker_s {
    pthread_t        tid;
    int              id;
    client          *worker_client;   /* preallocated by main thread */

    /* SPSC queue: the dispatcher (main thread) is the only producer, the
     * worker is the only consumer.  Keeping head/tail on separate cache
     * lines matches the SPSC design used by ring_buffer.h. */
    _Alignas(64) _Atomic(uint64_t) head;
    char              _pad0[64 - sizeof(_Atomic(uint64_t))];
    _Alignas(64) _Atomic(uint64_t) tail;
    char              _pad1[64 - sizeof(_Atomic(uint64_t))];
    struct DirectRequest *slots[DWP_QUEUE_SIZE];

    /* Wake channel: simple cond/mutex.  Worker waits when head==tail.
     * A dedicated eventfd would save a syscall but complicates portability
     * (iOS has no eventfd); cond_wait is good enough while the flag is
     * off-by-default. */
    pthread_mutex_t   wake_mtx;
    pthread_cond_t    wake_cv;

    /* MPSC push serializer.  Original design had one producer (the event
     * loop) calling queue_push.  The direct app-thread path
     * (dwp_try_direct) lets any JNI caller push straight into a worker
     * queue, bypassing the single-threaded event loop dispatcher.  That
     * makes queue_push MPSC, so producers serialize here while the
     * consumer side (queue_pop) stays lock-free.  Per-worker rather than
     * global: with 4 workers and N agents the effective contention per
     * mutex is N/4, and writers never wait for readers of other slots. */
    pthread_mutex_t   push_mtx;

    _Atomic(int)      stop;
} worker_t;

static worker_t       s_workers[DWP_MAX_WORKERS];
static int            s_n_workers   = 0;
static _Atomic(int)   s_enabled     = 0;   /* env + init guard */
static int            s_initialized = 0;

/* ── crc16 for slot computation ─────────────────────────────────────────── */

/* Valkey exposes keyHashSlot(key, keylen) in cluster.h; it handles hash-tag
 * `{...}` logic the same way the real cluster dispatch would.  Reusing it
 * guarantees that two workers never disagree on which slot a given key
 * lives in, even for multi-key pipelines. */

uint32_t dwp_key_slot(const char *key, int keylen) {
    if (!key || keylen <= 0) return 0;
    return (uint32_t)keyHashSlot((char *)key, keylen);
}

/* ── Hot-command lookup cache ──────────────────────────────────────────── *
 *
 * Every worker_execute call normally runs lookupCommand() to resolve argv[0]
 * into a `struct serverCommand *`.  That walks server.commands via
 * dictFindIntern, does ASCII case normalization, and even for the hot read
 * commands costs ~3–5 µs per request.  We call strcmp-based dispatch over
 * the handful of commands that the direct path and the Kotlin caller side
 * actually issue, cache the serverCommand pointers lazily on the first hit,
 * and fall through to lookupCommand() for anything else.
 *
 * The cache is write-once on worker bring-up (really: on first use) and
 * read-only thereafter.  No locking needed — racy initial fill is benign
 * because every concurrent filler writes the same pointer. */
enum {
    HOT_CMD_GET = 0,
    HOT_CMD_HGET,
    HOT_CMD_HMGET,
    HOT_CMD_HGETALL,
    HOT_CMD_HKEYS,
    HOT_CMD_HVALS,
    HOT_CMD_HLEN,
    HOT_CMD_HEXISTS,
    HOT_CMD_EXISTS,
    HOT_CMD_STRLEN,
    HOT_CMD_TYPE,
    HOT_CMD_LLEN,
    HOT_CMD_COUNT
};

static const char *const s_hot_cmd_names[HOT_CMD_COUNT] = {
    "GET","HGET","HMGET","HGETALL","HKEYS","HVALS",
    "HLEN","HEXISTS","EXISTS","STRLEN","TYPE","LLEN"
};

static _Atomic(struct serverCommand *) s_hot_cmd_cache[HOT_CMD_COUNT] = {0};

/* Case-insensitive strict 3- to 8-char match without allocating an sds.
 * Returns the hot-cmd index or -1. */
static inline int hot_cmd_index(const char *name) {
    if (!name) return -1;
    /* Uppercased first char lookup table to bucket fast; the set of hot
     * names only starts with E/G/H/L/S/T so 6 buckets. */
    char c0 = name[0];
    if (c0 >= 'a' && c0 <= 'z') c0 -= 32;
    for (int i = 0; i < HOT_CMD_COUNT; i++) {
        const char *h = s_hot_cmd_names[i];
        if (h[0] != c0) continue;
        const char *p = name + 1;
        const char *q = h + 1;
        while (*p && *q) {
            char a = *p, b = *q;
            if (a >= 'a' && a <= 'z') a -= 32;
            if (a != b) break;
            p++; q++;
        }
        if (*p == '\0' && *q == '\0') return i;
    }
    return -1;
}

static inline struct serverCommand *hot_cmd_lookup(robj **argv, int argc,
                                                   const char *name) {
    int idx = hot_cmd_index(name);
    if (idx < 0) return lookupCommand(argv, argc);
    struct serverCommand *cached =
        atomic_load_explicit(&s_hot_cmd_cache[idx], memory_order_acquire);
    if (cached) return cached;
    struct serverCommand *resolved = lookupCommand(argv, argc);
    if (resolved)
        atomic_store_explicit(&s_hot_cmd_cache[idx], resolved,
                              memory_order_release);
    return resolved;
}

/* ── Queue helpers (MPSC) ───────────────────────────────────────────────── */

/* Push under push_mtx so both the event-loop dispatcher and the direct
 * JNI path can share one queue per worker.  queue_pop stays lock-free. */
static inline int queue_push(worker_t *w, struct DirectRequest *req) {
    pthread_mutex_lock(&w->push_mtx);
    uint64_t h = atomic_load_explicit(&w->head, memory_order_relaxed);
    uint64_t t = atomic_load_explicit(&w->tail, memory_order_acquire);
    if (h - t >= DWP_QUEUE_SIZE) {
        pthread_mutex_unlock(&w->push_mtx);
        return 0;   /* full */
    }
    w->slots[h & DWP_QUEUE_MASK] = req;
    atomic_store_explicit(&w->head, h + 1, memory_order_release);
    pthread_mutex_unlock(&w->push_mtx);
    return 1;
}

static inline struct DirectRequest *queue_pop(worker_t *w) {
    uint64_t t = atomic_load_explicit(&w->tail, memory_order_relaxed);
    uint64_t h = atomic_load_explicit(&w->head, memory_order_acquire);
    if (t == h) return NULL;
    struct DirectRequest *req = w->slots[t & DWP_QUEUE_MASK];
    atomic_store_explicit(&w->tail, t + 1, memory_order_release);
    return req;
}

/* ── Worker thread ──────────────────────────────────────────────────────── */

/* Build robj** from the plain C argv the dispatcher handed over, run the
 * command on the worker's preallocated client, and marshal the reply.
 *
 * EVERYTHING ABOUT THIS FUNCTION IS UNSAFE without the upstream thread-safe
 * patch: call() touches server.current_client, dbFind may rehash the slot
 * dict, propagateNow may touch the AOF buffer.  Shadow mode prevents it
 * from ever running by short-circuiting at the dwp_enabled() check in
 * dwp_enqueue().  Kept here so the patch author can validate the worker
 * loop in isolation after the patch lands. */
static void worker_execute(worker_t *w, struct DirectRequest *req) {
    int          argc = dwp_request_argc(req);
    const char **argv_s = dwp_request_argv(req);
    if (argc <= 0 || !argv_s) {
        dwp_request_set_result(req, strdup("-ERR bad request\r\n"));
        return;
    }

    client *c = w->worker_client;

    /* Stack-allocate argv for the common case.  Every hot read the direct
     * path dispatches has argc ≤ ~8 (HMGET with a handful of fields being
     * the worst).  A stack array skips two zmalloc / zfree round-trips per
     * request, which at 900+ ops/s adds up to measurable CPU time. */
    robj  *argv_stack[16];
    robj **argv = (argc <= 16) ? argv_stack : zmalloc(argc * sizeof(robj *));
    for (int i = 0; i < argc; i++)
        argv[i] = createStringObject(argv_s[i], strlen(argv_s[i]));

    c->argc = argc;
    c->argv = argv;
    /* hot_cmd_lookup caches serverCommand* pointers for the dozen or so
     * read commands the direct path actually dispatches, avoiding a
     * dictFindIntern over server.commands on every call. */
    c->cmd  = c->lastcmd = c->realcmd = hot_cmd_lookup(argv, argc, argv_s[0]);

    /* Global barrier rdlock: excluded only by non-whitelisted main-thread
     * commands (EVAL, EVALSHA, ...) whose keyspace footprint argv[1] cannot
     * describe.  Taken BEFORE the slot lock so the barrier writer and slot
     * holders never nest in the wrong order. */
    dwp_global_rdlock();

    /* Slot rwlock: reads take the rdlock (concurrent across workers on the
     * same slot), writes take the wrlock (exclusive across the entire stripe
     * vs. main thread + every other worker). */
    uint32_t slot = dwp_request_slot(req);
    int      is_write = dazzle_slot_safe_write_cmd(argv_s[0]);

    if (is_write) dwp_slot_wrlock(slot);
    else          dwp_slot_rdlock(slot);

    if (!c->cmd) {
        addReplyErrorFormat(c, "ERR unknown command '%s'",
                            argc > 0 ? (char *)argv[0]->ptr : "");
    } else if (!is_write && (c->cmd->flags & CMD_READONLY)) {
        /* Lean read path: run the command proc directly, skipping every
         * shared-state mutation call() does post-proc (commandstats,
         * latency histogram, replicationFeedMonitors, alsoPropagate,
         * trackingRememberKeys, afterCommand).  Those are the sites that
         * race between workers on the same stripe.  For a pure read the
         * proc only needs a non-NULL c->db (checked above) and a valid
         * TLS executing_client (wired in worker_main). */
        c->flag.executing_command = 1;
        c->cmd->proc(c);
        c->flag.executing_command = 0;
    } else {
        /* Writes still go through call() so alsoPropagate / AOF path
         * runs consistently.  CMD_CALL_NONE already disables AOF/replica
         * propagation that this embedded single-primary build does not
         * need. */
        call(c, CMD_CALL_NONE);
    }

    /* Marshal reply into a heap string, same shape as extract_reply() in
     * dazzle_transport.c; duplicated here to avoid exporting that helper. */
    size_t total = c->bufpos;
    listIter li; listNode *ln;
    listRewind(c->reply, &li);
    while ((ln = listNext(&li)) != NULL) {
        clientReplyBlock *b = listNodeValue(ln);
        total += b->used;
    }

    char *out;
    if (total == 0) {
        out = strdup("+OK\r\n");
    } else {
        out = malloc(total + 1);
        if (out) {
            memcpy(out, c->buf, c->bufpos);
            size_t off = c->bufpos;
            listRewind(c->reply, &li);
            while ((ln = listNext(&li)) != NULL) {
                clientReplyBlock *b = listNodeValue(ln);
                memcpy(out + off, b->buf, b->used);
                off += b->used;
            }
            out[off] = '\0';
        } else {
            out = strdup("-ERR out of memory\r\n");
        }
    }
    dwp_request_set_result(req, out);

    /* Keep the HMGET snapshot cache in sync for the handful of write
     * commands the fast-read path mirrors.  Runs under the slot wrlock so
     * the cache update is atomic with the kvstore mutation. */
    if (is_write)
        dazzle_snapshot_mirror_write(argc, argv_s, out);

    dwp_slot_unlock(slot);
    dwp_global_unlock();

    /* Release argv refs manually and detach from the client before
     * resetClient() runs freeClientArgv() → zfree(c->argv).  If argv
     * landed on the stack (common case, argc ≤ 16) that zfree would
     * crash. */
    for (int i = 0; i < argc; i++) decrRefCount(argv[i]);
    if (argv != argv_stack) zfree(argv);
    c->argv = NULL;
    c->argc = 0;

    /* Lean reset: skip resetClient()'s flag bookkeeping
     * (commitDeferredReplyBuffer, asking/tracking_caching, replication
     * accounting, net_input/output counters).  Our fake client runs one
     * whitelisted read at a time and never touches those paths, so the
     * only state that actually needs clearing between commands is
     * cmd/parsed_cmd, slot, reply buffer, and the reply list.  argv was
     * already released manually above. */
    c->cmd          = c->lastcmd = c->realcmd = NULL;
    c->parsed_cmd   = NULL;
    c->cur_script   = NULL;
    c->slot         = -1;
    c->bufpos       = 0;
    c->reply_bytes  = 0;
    if (listLength(c->reply)) {
        listSetFreeMethod(c->reply, freeClientReplyValue);
        listEmpty(c->reply);
        listSetFreeMethod(c->reply, NULL);
    }
}

static void *worker_main(void *arg) {
    worker_t *w = (worker_t *)arg;

    /* Set thread name so `ps -T` on Android and Instruments on iOS show
     * which Dazzle threads are the read workers.  16-char limit on Linux. */
    char name[16];
    snprintf(name, sizeof name, "dazzle-w%d", w->id);
#if defined(__ANDROID__)
    pthread_setname_np(pthread_self(), name);
#elif defined(VALKEY_IOS)
    /* pthread_setname_np may not be forward-declared on all iOS SDK versions */
    extern int pthread_setname_np(const char *) __attribute__((weak));
    if (pthread_setname_np) pthread_setname_np(name);
#endif

    /* Patch 04 contract: each worker owns its TLS slot for the whole
     * lifetime.  call() and command procs read server_current_client
     * (macro → dazzle_tls_current_client) instead of the struct field, so
     * the main thread and this worker can process commands concurrently
     * without clobbering each other. */
    dazzle_tls_current_client   = w->worker_client;
    dazzle_tls_executing_client = w->worker_client;

    for (;;) {
        struct DirectRequest *req = queue_pop(w);
        if (req) {
            worker_execute(w, req);
            dwp_request_signal_done(req);
            continue;
        }

        if (atomic_load_explicit(&w->stop, memory_order_acquire)) break;

        /* Block on cv; dwp_enqueue signals after push. */
        pthread_mutex_lock(&w->wake_mtx);
        /* Re-check after taking the lock to close the push/wake race. */
        if (atomic_load_explicit(&w->head, memory_order_acquire) ==
            atomic_load_explicit(&w->tail, memory_order_relaxed) &&
            !atomic_load_explicit(&w->stop, memory_order_acquire)) {
            pthread_cond_wait(&w->wake_cv, &w->wake_mtx);
        }
        pthread_mutex_unlock(&w->wake_mtx);
    }

    return NULL;
}

/* ── Client preallocation (main thread) ─────────────────────────────────── */

/* Allocate a Dazzle fake client using the exact invariants from
 * directCommandHandler's s_fake init: cached-response id + stub connection
 * + flag.fake + sds peerid.  Called from dwp_init() on the main thread so
 * no concurrent modification of server.clients is possible. */
static client *create_worker_client(int worker_id) {
    client *c = createClient(NULL);
    if (!c) return NULL;

    c->id   = CLIENT_ID_CACHED_RESPONSE;
    c->conn = zcalloc(sizeof(connection));
    c->flag.fake          = 1;
    c->flag.deny_blocking = 1;
    c->flag.authenticated = 1;
    /* Blocker D root cause: prepareClientToWrite() → putClientInPendingWriteQueue()
     * mutates the global server.clients_pending_write linked list via
     * listLinkNodeHead() without any lock.  With workers + main thread both
     * running addReply*() from different threads, that list corrupts and
     * subsequent dereferences crash at whatever offset the torn struct lands
     * on (observed 0x88, then 0x90).  Preset the pending_write flag so the
     * putClientInPendingWriteQueue() guard `!c->flag.pending_write` short-
     * circuits and the worker never touches the global list.  The worker
     * reads its reply straight from c->buf / c->reply and never needs a
     * socket write, so staying out of the queue is correct. */
    c->flag.pending_write = 1;
    c->resp = 2;

    char label[32];
    snprintf(label, sizeof label, "dazzle-wpool-%d:0", worker_id);
    c->peerid   = sdsnew(label);
    c->sockname = sdsnew(label);
    selectDb(c, 0);
    return c;
}

/* ── Public API ────────────────────────────────────────────────────────── */

static int pick_worker_count(void) {
    const char *env = getenv("DAZZLE_WORKER_THREADS");
    if (env && *env) {
        int n = atoi(env);
        if (n < 1) n = 1;
        if (n > DWP_MAX_WORKERS) n = DWP_MAX_WORKERS;
        return n;
    }
    /* Conservative default: leave one core for the main event loop. */
    long hw = sysconf(_SC_NPROCESSORS_ONLN);
    int n = (hw > 1) ? (int)(hw - 1) : 1;
    if (n > 4) n = 4;   /* Default cap; tune in M5 per SoC. */

#if defined(__ANDROID__)
    /* SoC-aware cap: small-core-only phones (e.g., Moto g35 class —
     * 8× Cortex-A55 @ 2.0-2.2 GHz) benchmark identically with 2 vs 4
     * workers (940 ≈ 932 ops/s on K=8).  Workers park on cond_wait
     * most of the time, so extra workers just waste pthread stacks
     * and confuse the scheduler.  Detect "no big cores" by scanning
     * /sys/.../cpuinfo_max_freq and cap at 2 in that case.
     *
     * Threshold 2.4 GHz: bigger than every A55 SKU, smaller than the
     * big / prime core of every recent big.LITTLE design (A76 @ 2.5+,
     * A77/A78 @ 2.6+, X1/X2/X3 @ 2.8+).  If sysfs reads fail on every
     * core (SELinux shouldn't block this one, but just in case) we
     * keep the original uncapped value — we'd rather overshoot on an
     * unknown device than cripple a big-core chip. */
    int big_cores = 0;
    int reads_ok  = 0;
    for (int i = 0; i < hw && i < 32; i++) {
        char path[128];
        snprintf(path, sizeof path,
                 "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        long khz = 0;
        if (fscanf(f, "%ld", &khz) == 1 && khz > 0) {
            reads_ok++;
            if (khz >= 2400000) big_cores++;
        }
        fclose(f);
    }
    if (reads_ok > 0 && big_cores == 0 && n > 2) {
        serverLog(LL_NOTICE,
            "dazzle-wpool: small-cores-only SoC detected (%d cores, "
            "max freq < 2.4 GHz) — capping worker count at 2", (int)hw);
        n = 2;
    }
#endif

    if (n > DWP_MAX_WORKERS) n = DWP_MAX_WORKERS;
    return n;
}

static int flag_requested(void) {
    const char *env = getenv("DAZZLE_PARALLEL_READS");
    return env && env[0] == '1' && env[1] == '\0';
}

int dwp_init(void) {
    if (s_initialized) return 0;

    /* Plan 09: poll DAZZLE_EVAL_KEY_LOCKS once per fresh server start,
     * same contract as DAZZLE_PARALLEL_READS below. */
    reload_eval_key_locks_flag();

    memset(s_workers, 0, sizeof s_workers);

    /* Striped rwlocks.  Writer preference on Android/glibc keeps writes from
     * starving under the 80/20 read-heavy bench; POSIX default (bionic) is
     * "fair", which is acceptable but slower for writes.  The _np call is
     * safely a no-op on platforms that don't expose it. */
    pthread_rwlockattr_t attr;
    pthread_rwlockattr_init(&attr);
#if defined(PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP)
    pthread_rwlockattr_setkind_np(&attr,
        PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP);
#endif
    for (int i = 0; i < DWP_LOCK_STRIPES; i++)
        pthread_rwlock_init(&s_slot_locks[i], &attr);
    pthread_rwlock_init(&s_global_barrier, &attr);
    pthread_rwlockattr_destroy(&attr);
    s_slot_locks_initialized     = 1;
    s_global_barrier_initialized = 1;

    s_n_workers = pick_worker_count();

    for (int i = 0; i < s_n_workers; i++) {
        worker_t *w = &s_workers[i];
        w->id = i;
        atomic_store_explicit(&w->head, 0, memory_order_relaxed);
        atomic_store_explicit(&w->tail, 0, memory_order_relaxed);
        atomic_store_explicit(&w->stop, 0, memory_order_relaxed);
        pthread_mutex_init(&w->wake_mtx, NULL);
        pthread_mutex_init(&w->push_mtx, NULL);
        pthread_cond_init(&w->wake_cv,   NULL);

        w->worker_client = create_worker_client(i);
        if (!w->worker_client) {
            serverLog(LL_WARNING,
                "dazzle-wpool: createClient failed for worker %d", i);
            s_n_workers = i;
            break;
        }

        if (pthread_create(&w->tid, NULL, worker_main, w) != 0) {
            serverLog(LL_WARNING,
                "dazzle-wpool: pthread_create failed for worker %d: %s",
                i, strerror(errno));
            s_n_workers = i;
            break;
        }
    }

    s_initialized = 1;
    if (flag_requested() && s_n_workers > 0) {
        atomic_store_explicit(&s_enabled, 1, memory_order_release);
        /* Blocker D resolved (pending_write preset on every fake client
         * keeps the global server.clients_pending_write list untouched
         * by the parallel path).  Reads on the dazzle_slot_safe_cmd
         * whitelist now offload; writes + anything outside the
         * whitelist still run on the event loop thread under the same
         * per-slot rwlock. */
        serverLog(LL_NOTICE,
            "dazzle-wpool: reads-only offload ENABLED (%d workers, %d "
            "slot-lock stripes)",
            s_n_workers, DWP_LOCK_STRIPES);
    } else {
        serverLog(LL_NOTICE,
            "dazzle-wpool: shadow mode (%d worker(s) idle, dispatch off)",
            s_n_workers);
    }
    return s_n_workers > 0 ? 0 : -1;
}

void dwp_shutdown(void) {
    if (!s_initialized) return;
    atomic_store_explicit(&s_enabled, 0, memory_order_release);
    for (int i = 0; i < s_n_workers; i++) {
        worker_t *w = &s_workers[i];
        pthread_mutex_lock(&w->wake_mtx);
        atomic_store_explicit(&w->stop, 1, memory_order_release);
        pthread_cond_signal(&w->wake_cv);
        pthread_mutex_unlock(&w->wake_mtx);
        pthread_join(w->tid, NULL);
        pthread_mutex_destroy(&w->wake_mtx);
        pthread_mutex_destroy(&w->push_mtx);
        pthread_cond_destroy(&w->wake_cv);
    }
    s_n_workers   = 0;
    s_initialized = 0;

    if (s_slot_locks_initialized) {
        for (int i = 0; i < DWP_LOCK_STRIPES; i++)
            pthread_rwlock_destroy(&s_slot_locks[i]);
        s_slot_locks_initialized = 0;
    }
    if (s_global_barrier_initialized) {
        pthread_rwlock_destroy(&s_global_barrier);
        s_global_barrier_initialized = 0;
    }
}

int dwp_enabled(void) {
    return atomic_load_explicit(&s_enabled, memory_order_acquire);
}

int dwp_worker_count(void) { return s_n_workers; }

int dwp_enqueue(struct DirectRequest *req) {
    if (!dwp_enabled() || s_n_workers == 0) return -1;

    uint32_t slot = dwp_request_slot(req);
    if (slot >= DWP_SLOTS) return -1;

    worker_t *w = &s_workers[slot % s_n_workers];
    if (!queue_push(w, req)) return -1;

    pthread_mutex_lock(&w->wake_mtx);
    pthread_cond_signal(&w->wake_cv);
    pthread_mutex_unlock(&w->wake_mtx);
    return 0;
}

#endif /* VALKEY_IOS || __ANDROID__ */
