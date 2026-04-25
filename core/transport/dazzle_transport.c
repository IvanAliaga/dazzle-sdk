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

/* dazzle_transport.c — In-process command execution that bypasses TCP loopback.
 *
 * Compiled WITH the Valkey source tree on both iOS and Android, so it has
 * full access to Valkey internals (server.h, ae.h, networking.c symbols).
 *
 * Architecture
 * ============
 * Valkey is single-threaded. All internal functions (createClient, call,
 * processCommand …) must run on the event loop thread. Commands arriving from
 * the app thread are dispatched via a Unix self-pipe registered with Valkey's
 * ae event loop:
 *
 *   App thread                        Event loop thread / worker
 *   ----------                        -----------------
 *   Build DirectRequest (init mtx+cv)
 *   Push pointer to ring / pipe  ---> handler/worker fires
 *   Wait on req->cv                   Execute call(), set req->result
 *                                     Lock req->mtx, done=1, signal req->cv
 *   Wake on own cv, destroy mtx+cv
 *   Return req.result
 *
 * dazzle_direct_init() is invoked from a one-line patch to server.c
 * (added by build.sh / apply_patches.sh) right after InitServerLast(), so it
 * runs on the server thread and can safely call aeCreateFileEvent().
 *
 * Thread safety
 * =============
 * Each DirectRequest owns its own (mutex, condvar) pair. A producer (event
 * loop handler or worker) signals exactly one waiter via the request's own
 * cv — no shared condvar, no thundering herd, no wrong-thread wakes. This
 * is what makes K concurrent coroutines make progress independently: thread
 * A completing request A cannot accidentally re-sleep thread B whose
 * request is still in flight. Pipe writes of 8-byte pointer payloads are
 * atomic per POSIX PIPE_BUF, so no global write lock is required.
 */

#if defined(VALKEY_IOS) || defined(__ANDROID__)

#include "server.h"
#include "ae.h"

#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>

#include "dazzle_worker_pool.h"
#include "dazzle_slot_safe.h"

/* Phase 2: lock-free SPSC ring buffer (Android only — eventfd is Linux).
 * On iOS, the ring buffer header is still included but the eventfd path
 * is guarded by __ANDROID__ so only the fallback pipe path is used. */
#ifdef __ANDROID__
#include "ring_buffer.h"
#include "io_uring_transport.h"
#endif

/* ---------- shared state -------------------------------------------- */

typedef struct DirectRequest {
    int              argc;
    const char     **argv_strs;    /* plain C strings, owned by the caller */
    char            *result;       /* heap RESP string; caller must free() */
    _Atomic(int)     done;         /* set by handler/worker after result   */
    uint32_t         slot;         /* Plan 02: slot for worker-pool dispatch */
    pthread_mutex_t  mtx;          /* per-request wait channel             */
    pthread_cond_t   cv;           /* signalled by producer once done=1    */
} DirectRequest;

/* ── Per-request wait channel helpers ──────────────────────────────────── *
 * Each request owns its own (mtx, cv). A producer signals exactly one       *
 * waiter via the request's own cv — no shared condvar, no thundering herd.  *
 * Stack-allocated requests must call req_init/req_destroy inside the same   *
 * frame; heap requests do the same at alloc/free time.                      *
 * ─────────────────────────────────────────────────────────────────────────── */

static inline void req_init(DirectRequest *req) {
    pthread_mutex_init(&req->mtx, NULL);
    pthread_cond_init(&req->cv,   NULL);
    atomic_store_explicit(&req->done, 0, memory_order_relaxed);
    req->result = NULL;
}

static inline void req_destroy(DirectRequest *req) {
    pthread_mutex_destroy(&req->mtx);
    pthread_cond_destroy(&req->cv);
}

static inline void req_wait(DirectRequest *req) {
    pthread_mutex_lock(&req->mtx);
    while (!atomic_load_explicit(&req->done, memory_order_acquire))
        pthread_cond_wait(&req->cv, &req->mtx);
    pthread_mutex_unlock(&req->mtx);
}

static inline void req_signal_done(DirectRequest *req) {
    if (!req) return;
    pthread_mutex_lock(&req->mtx);
    atomic_store_explicit(&req->done, 1, memory_order_release);
    pthread_cond_signal(&req->cv);
    pthread_mutex_unlock(&req->mtx);
}

/* ── Plan 02 accessors (opaque view of DirectRequest for worker_pool.c) ── */
int dwp_request_argc(const struct DirectRequest *req) {
    return req ? req->argc : 0;
}
const char **dwp_request_argv(const struct DirectRequest *req) {
    return req ? req->argv_strs : NULL;
}
void dwp_request_set_result(struct DirectRequest *req, char *result) {
    if (req) req->result = result;
}
uint32_t dwp_request_slot(const struct DirectRequest *req) {
    return req ? req->slot : 0;
}

/* Plan 09 — EVAL / EVALSHA key-slot extraction.
 *
 * argv layout: <cmd> <body|sha> <numkeys> key1 … keyN arg1 …
 *
 * When EVAL/EVALSHA declares its keyspace footprint via the numkeys/keys
 * preamble we can take fine-grained wrlocks on exactly those stripes
 * instead of the nuclear global_wrlock. This is the hot PAR-mode
 * bottleneck for the Dazzle benchmarks (incremental and precompute
 * ingest both use EVALSHA). Correctness rests on the Redis/Valkey
 * convention that scripts only access keys declared in KEYS.
 *
 * Returns 1 when the command is EVAL/EVALSHA with a valid numkeys > 0,
 * fills out_slots[0..*out_nkeys-1] with unreduced stripe-mask ids, and
 * sets *out_nkeys ≤ DAZZLE_MAX_EVAL_KEYS. Returns 0 otherwise (caller
 * falls back to the legacy global_wrlock path).
 *
 * A caller must still wrap the stripe locks in dwp_global_rdlock so the
 * barrier writer path (every non-whitelisted command that is NOT
 * EVAL/EVALSHA, or EVAL with numkeys=0) continues to exclude the worker
 * pool correctly. */
#define DAZZLE_MAX_EVAL_KEYS 16

static int dazzle_eval_extract_slots(int argc, const char *const *argv,
                                     uint32_t *out_slots, int *out_nkeys) {
    if (argc < 3 || !argv || !argv[0] || !argv[2]) return 0;
    const char *cmd = argv[0];
    if (strcasecmp(cmd, "EVAL") != 0 && strcasecmp(cmd, "EVALSHA") != 0)
        return 0;
    char *endp = NULL;
    long numkeys = strtol(argv[2], &endp, 10);
    if (numkeys <= 0 || numkeys > DAZZLE_MAX_EVAL_KEYS) return 0;
    if ((long)argc < 3 + numkeys) return 0;
    for (long i = 0; i < numkeys; i++) {
        const char *k = argv[3 + i];
        if (!k) return 0;
        out_slots[i] = dwp_key_slot(k, (int)strlen(k));
    }
    *out_nkeys = (int)numkeys;
    return 1;
}

/* Plan 02: worker threads call this to wake the waiter on its DirectRequest. */
void dwp_request_signal_done(struct DirectRequest *req) {
    req_signal_done(req);
}

/* ── Heap factory API ──────────────────────────────────────────────────── *
 * Exposed so external callers (dazzle_jni.c pipeline path) do not need to   *
 * duplicate the DirectRequest layout. The factory owns init/destroy of the  *
 * per-request mutex+cv so callers only see an opaque pointer.               *
 * ─────────────────────────────────────────────────────────────────────────── */

DirectRequest *dazzle_request_new(int argc, const char **argv_strs) {
    DirectRequest *req = (DirectRequest *)calloc(1, sizeof(DirectRequest));
    if (!req) return NULL;
    req->argc      = argc;
    req->argv_strs = argv_strs;
    req->slot      = (argc >= 2 && argv_strs && argv_strs[1])
        ? dwp_key_slot(argv_strs[1], (int)strlen(argv_strs[1]))
        : 0;
    req_init(req);
    return req;
}

void dazzle_request_free(DirectRequest *req) {
    if (!req) return;
    req_destroy(req);
    free(req);
}

char *dazzle_request_take_result(DirectRequest *req) {
    if (!req) return NULL;
    char *r = req->result;
    req->result = NULL;
    return r;
}

static int s_pipe[2] = {-1, -1};

/* Try to hand a request to the worker pool.  Returns 1 when the request
 * has been queued (caller must NOT execute it inline); 0 when the caller
 * should fall through to the single-thread path (pool disabled, queue
 * full, or command not on either safe list).
 *
 * Plan 02 / Stage 1 (reads-only): offload commands on the
 * dazzle_slot_safe_cmd whitelist (GET/HGET/HMGET/HGETALL/…) to workers,
 * run everything else on the event loop thread.  The worker pool takes
 * a per-slot rdlock; the main-thread path below takes the same stripe's
 * rdlock/wrlock depending on the command class, so concurrent reads
 * scale while writes remain serialized.
 *
 * Previous 0x88/0x90 SIGSEGVs under K=8 sustained load were not call()
 * side effects — they were pointer corruption from unguarded writes to
 * the global server.clients_pending_write linked list in
 * putClientInPendingWriteQueue().  That list is mutated from addReply*()
 * on every fake client + every worker concurrently, and listLinkNodeHead
 * is not lock-protected.  Fix lives on the producer side: both the
 * worker_client (create_worker_client) and the main-thread s_fake are
 * initialized with `flag.pending_write = 1`, which short-circuits the
 * putClientInPendingWriteQueue guard so neither ever touches the list.
 * Workers drain their reply buffers directly in worker_execute(), so
 * staying out of the pending-write queue is functionally correct. */
static int try_offload_to_worker(DirectRequest *req) {
    if (req->argc <= 0 || !req->argv_strs || !req->argv_strs[0]) return 0;
    if (!dazzle_slot_safe_cmd(req->argv_strs[0])) return 0;
    return dwp_enqueue(req) == 0;
}

/* ── Phase 2: ring buffer transport (Android only) ──────────────────────── *
 * When available, write commands are dispatched via an SPSC ring buffer +   *
 * eventfd wakeup instead of the OS pipe.  The pipe is kept as fallback for  *
 * ring-full conditions and for iOS (no eventfd).                             *
 * ─────────────────────────────────────────────────────────────────────────── */
#ifdef __ANDROID__
static spsc_ring_t  s_write_ring;
static int          s_ring_efd   = -1;   /* eventfd for wakeup        */
static _Atomic(int) s_ring_active = 0;   /* 1 = ring path ready       */

/* Phase 3: io_uring batch notify */
static uring_ctx_t  s_uring;
static _Atomic(int) s_uring_active = 0;  /* 1 = io_uring path ready   */
#endif

/* Single fake client reused across every call to avoid per-command
 * allocation overhead. Allocated lazily on the first direct command. */
static client *s_fake = NULL;

/* ── Snapshot cache for directRead() ─────────────────────────────────── *
 * Mirrors every HSET / HINCRBY / HINCRBYFLOAT written through the pipe.  *
 * The event loop thread updates the cache (write-lock) immediately after  *
 * executing the command.  The app thread reads it (read-lock) in          *
 * dazzle_direct_read() without touching any Valkey internals.      *
 *                                                                          *
 * Consistency: the pipe is fully synchronous.  ingest() blocks the app    *
 * thread until the event loop signals the condvar.  By the time           *
 * buildContextBlock() calls directRead(), every preceding HSET/HINCRBY    *
 * has already run and the snapshot is up to date.  Zero staleness.        *
 *                                                                          *
 * Indexing (Plan 08 / v1.2):                                               *
 *   The snapshot is sharded into SNAP_BUCKETS power-of-2 buckets keyed by  *
 *   FNV-1a 32-bit hash of the Valkey key.  Each bucket owns an             *
 *   independent pthread_rwlock_t, so cross-key reads on different buckets  *
 *   run fully in parallel — critical at K=8 workers.  A process-wide       *
 *   s_snap_flush_rwlock serialises FLUSHDB / FLUSHALL against every        *
 *   other operation (readers take its rdlock, FLUSHDB takes wrlock).      *
 *   Lookup within a bucket is an O(load-factor) linear scan with a         *
 *   precomputed-hash fast reject — with 128 total entries across 16        *
 *   buckets the average scan length is 1–2.                                 *
 * ──────────────────────────────────────────────────────────────────────── */

#define SNAP_BUCKETS              16   /* power of 2; masked in snap_bucket */
#define SNAP_MAX_ENTRIES_PER_BUCKET 16
#define SNAP_MAX_FIELDS   64
#define SNAP_KEY_LEN     128
#define SNAP_VAL_LEN     256

/* Phase 2 — one SnapEntry holds any of four Valkey data types. The storage
 * layout is shared (same `fields[]` array) but `type` tells the reader how
 * to interpret each slot:
 *
 *   SNAP_TYPE_HASH    : fields[i].f = hash field name, fields[i].v = value
 *   SNAP_TYPE_SET     : fields[i].f = set member,      fields[i].v = ""
 *   SNAP_TYPE_ZSET    : fields[i].f = zset member,     fields[i].v = score as string
 *   SNAP_TYPE_STRING  : fields[0].f = "",              fields[0].v = value (nfields == 1)
 *
 * Reusing the existing SnapField[] buffer keeps the total snapshot memory
 * (≈6.3 MB across 256 entries) unchanged — Phase 2 costs zero bytes.
 */
#define SNAP_TYPE_HASH   0
#define SNAP_TYPE_SET    1
#define SNAP_TYPE_ZSET   2
#define SNAP_TYPE_STRING 3

typedef struct { char f[SNAP_KEY_LEN]; char v[SNAP_VAL_LEN]; } SnapField;
typedef struct {
    uint32_t  key_hash;   /* precomputed FNV-1a; 0 only if valid==0         */
    int       valid;
    int       type;       /* SNAP_TYPE_* — see block comment above         */
    int       nfields;
    /* Sticky "this key overflowed a SnapField buffer, don't try to cache
     * it again until the key is DEL'd". Prevents partial-data reads when
     * a long member invalidates the entry and a subsequent short member
     * would otherwise re-create it with only a subset of the real keyspace.
     * Cleared by the DEL/UNLINK handler and by ZADD→TYPE change. */
    int       poisoned;
    char      key[SNAP_KEY_LEN];
    SnapField fields[SNAP_MAX_FIELDS];
} SnapEntry;

typedef struct {
    pthread_rwlock_t rwlock;
    int              n;
    SnapEntry        entries[SNAP_MAX_ENTRIES_PER_BUCKET];
} SnapBucket;

static SnapBucket       s_snap[SNAP_BUCKETS];
static pthread_rwlock_t s_snap_flush_rwlock = PTHREAD_RWLOCK_INITIALIZER;
static pthread_once_t   s_snap_once         = PTHREAD_ONCE_INIT;

/* ── Ablation knobs (plan 08 paper) ────────────────────────────────────── *
 * DAZZLE_DISABLE_SNAPSHOT=1 → all read paths return miss and mirror_write *
 *   becomes a no-op. Lets the paper measure the pipe-only baseline without *
 *   rebuilding the APK.                                                    *
 * DAZZLE_SNAPSHOT_BUCKETS=1 → force the FNV-1a bucket mask to 0, so every *
 *   key collides into bucket 0. Lets the paper isolate the O(1) dispatch  *
 *   contribution from the rest of the snapshot cache.                     *
 *                                                                          *
 * Both flags are polled via dazzle_snapshot_reload_config() which is       *
 * invoked automatically from dazzle_direct_init() — so every fresh server  *
 * start re-reads them, matching the DAZZLE_PARALLEL_READS contract.        *
 * ──────────────────────────────────────────────────────────────────────── */
static atomic_int      s_snap_disabled    = 0;
static atomic_uint     s_snap_bucket_mask = (unsigned)(SNAP_BUCKETS - 1);

static void snap_init_buckets(void) {
    for (int b = 0; b < SNAP_BUCKETS; b++) {
        pthread_rwlock_init(&s_snap[b].rwlock, NULL);
        s_snap[b].n = 0;
    }
}

/* Read the ablation env vars once, promote the result into the atomics that
 * every read/write path consults.  Safe to call from any thread; subsequent
 * readers will see the new values via release/acquire. */
void dazzle_snapshot_reload_config(void) {
    const char *dis = getenv("DAZZLE_DISABLE_SNAPSHOT");
    atomic_store_explicit(&s_snap_disabled,
                          (dis && dis[0] == '1' && dis[1] == '\0') ? 1 : 0,
                          memory_order_release);

    const char *nb = getenv("DAZZLE_SNAPSHOT_BUCKETS");
    unsigned mask = (unsigned)(SNAP_BUCKETS - 1);
    if (nb) {
        long n = strtol(nb, NULL, 10);
        if (n == 1)             mask = 0u;
        else if (n >= SNAP_BUCKETS) mask = (unsigned)(SNAP_BUCKETS - 1);
        /* Non-power-of-2 or out-of-range values silently keep the default. */
    }
    atomic_store_explicit(&s_snap_bucket_mask, mask, memory_order_release);
}

/* FNV-1a 32-bit hash — fast, no dependencies, well-distributed on short
 * ASCII keys like "sensor:stats" / "agent:checkpoint:5". */
static uint32_t snap_key_hash(const char *key) {
    uint32_t h = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)key; *p; p++) {
        h ^= *p;
        h *= 16777619u;
    }
    return h ? h : 1u;   /* reserve 0 for "unhashed" sentinel (unused) */
}

static inline SnapBucket *snap_bucket_for_hash(uint32_t hash) {
    unsigned mask = atomic_load_explicit(&s_snap_bucket_mask, memory_order_acquire);
    return &s_snap[hash & mask];
}

/* Find an entry inside a bucket the caller has already r/w-locked.
 * The precomputed-hash check rejects mismatches without a strcmp in the
 * common case, which is the whole point of storing key_hash per entry. */
static SnapEntry *snap_find_in_bucket(SnapBucket *b, uint32_t hash,
                                      const char *key) {
    int n = b->n;
    for (int i = 0; i < n; i++) {
        SnapEntry *e = &b->entries[i];
        if (e->valid && e->key_hash == hash && strcmp(e->key, key) == 0)
            return e;
    }
    return NULL;
}

/* Find-or-create. Caller must hold bucket wrlock. Returns NULL if the
 * bucket is full (rare — with 128 total entries across 16 buckets a
 * full bucket means the caller has >8 keys hashing to the same shard).
 *
 * `type` is the SNAP_TYPE_* the entry should hold. When an existing entry
 * has a DIFFERENT type (e.g. a key was DEL'd and reused as another data
 * type), we invalidate and reinitialise — snapshot semantics always match
 * what the last successful command did. */
static SnapEntry *snap_find_or_create_in_bucket(SnapBucket *b, uint32_t hash,
                                                const char *key, int type) {
    SnapEntry *e = snap_find_in_bucket(b, hash, key);
    if (e) {
        if (e->type != type) {
            /* Type change — wipe fields so stale pairs don't leak. */
            e->type    = type;
            e->nfields = 0;
        }
        return e;
    }

    /* Check for a poisoned entry with THIS key — we must not recreate it,
     * because the RESP-side keyspace holds data we can't represent in a
     * SnapField (long members). Writes become a snapshot-cache no-op for
     * this key; reads naturally miss and fall back to RESP. */
    for (int i = 0; i < b->n; i++) {
        SnapEntry *p = &b->entries[i];
        if (p->poisoned && p->key_hash == hash && strcmp(p->key, key) == 0) {
            return NULL;
        }
    }

    /* Reclaim an invalidated, NON-poisoned slot if one exists — lets
     * DEL'd keys recycle their storage rather than forcing growth
     * until the bucket is full. */
    for (int i = 0; i < b->n; i++) {
        if (!b->entries[i].valid && !b->entries[i].poisoned) {
            e = &b->entries[i];
            e->valid = 1;
            e->type = type;
            e->nfields = 0;
            e->key_hash = hash;
            strncpy(e->key, key, SNAP_KEY_LEN - 1);
            e->key[SNAP_KEY_LEN - 1] = '\0';
            return e;
        }
    }

    if (b->n >= SNAP_MAX_ENTRIES_PER_BUCKET) return NULL;
    e = &b->entries[b->n++];
    e->valid = 1;
    e->poisoned = 0;
    e->type = type;
    e->nfields = 0;
    e->key_hash = hash;
    strncpy(e->key, key, SNAP_KEY_LEN - 1);
    e->key[SNAP_KEY_LEN - 1] = '\0';
    return e;
}

/* Upsert field=value on an existing SnapEntry. Caller must hold bucket
 * wrlock.  Silently drops on SNAP_MAX_FIELDS overflow (same contract as
 * the pre-sharding implementation). */
/* Write one (field, value) pair into the entry's field array. The
 * buffers (SNAP_KEY_LEN / SNAP_VAL_LEN, 128 / 256 bytes) are intentionally
 * sized for typical keyspace shapes — user IDs, short references, score
 * strings. If a caller stores a longer member (e.g. a 200-byte JSON blob
 * in a ZSET for the `dazzle-precompute` pattern), we used to silently
 * truncate via strncpy, which corrupted the data on the read side.
 *
 * Correctness fix: detect the overflow, poison the entry (valid=0),
 * and return. Every subsequent read goes through snap_find_in_bucket's
 * `e->valid` check, misses, and falls back to the RESP path — which
 * has no length limit. The key stops being fast-path-cacheable but
 * returns correct data.
 *
 * For the typical case (short members) this adds only two strlen calls
 * on the write path — negligible vs the memcpy into the SnapField. */
static void snap_set_field(SnapEntry *e, const char *field, const char *value) {
    size_t fl = strlen(field);
    size_t vl = strlen(value);
    if (fl >= SNAP_KEY_LEN || vl >= SNAP_VAL_LEN) {
        /* Poison: long member detected. Mark both valid=0 (so reads
         * miss and fall back to RESP) and poisoned=1 (so later ZADD
         * for the same key doesn't re-create the slot with partial
         * data — see snap_find_or_create_in_bucket). */
        e->valid    = 0;
        e->poisoned = 1;
        return;
    }

    for (int j = 0; j < e->nfields; j++) {
        if (strcmp(e->fields[j].f, field) == 0) {
            memcpy(e->fields[j].v, value, vl + 1);
            return;
        }
    }
    if (e->nfields >= SNAP_MAX_FIELDS) {
        /* Entry full of short members — same rationale: can't cache
         * any new field safely, so fall back to RESP for this key. */
        e->valid    = 0;
        e->poisoned = 1;
        return;
    }
    SnapField *sf = &e->fields[e->nfields++];
    memcpy(sf->f, field, fl + 1);
    memcpy(sf->v, value, vl + 1);
}

/* Parse the numeric result out of a HINCRBY (:N\r\n) or HINCRBYFLOAT
 * ($len\r\nval\r\n) reply into buf[bufsz].  Returns buf on success, NULL
 * on parse failure.  Safe to call from the event-loop thread only. */
static const char *parse_incr_reply(const char *resp, char *buf, int bufsz) {
    if (!resp) return NULL;
    if (resp[0] == ':') {
        /* Integer reply: ":42\r\n" */
        const char *start = resp + 1;
        const char *end   = strstr(start, "\r\n");
        if (!end) return NULL;
        int len = (int)(end - start);
        if (len <= 0 || len >= bufsz) return NULL;
        memcpy(buf, start, len); buf[len] = '\0';
        return buf;
    }
    if (resp[0] == '$') {
        /* Bulk-string reply: "$4\r\n22.5\r\n" */
        const char *crlf = strstr(resp + 1, "\r\n");
        if (!crlf) return NULL;
        const char *val = crlf + 2;
        const char *end = strstr(val, "\r\n");
        if (!end) return NULL;
        int len = (int)(end - val);
        if (len <= 0 || len >= bufsz) return NULL;
        memcpy(buf, val, len); buf[len] = '\0';
        return buf;
    }
    return NULL;
}

/* ---------- snapshot mirror (shared between main loop and workers) --- */

/* Apply the subset of write commands we mirror into the HMGET snapshot
 * cache.  Exported under the C name `dazzle_snapshot_mirror_write` so
 * dazzle_worker_pool.c can call it from worker_execute(); the main event
 * loop and ring drain handler also route through here.  Acquires the
 * snapshot's own rwlock internally — safe from any thread. */
void dazzle_snapshot_mirror_write(int argc, const char *const *argv,
                                  const char *reply) {
    if (!argv || !argv[0] || argc < 2) return;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return;
    pthread_once(&s_snap_once, snap_init_buckets);

    const char *cmd = argv[0];
    const char *key = argv[1];

    /* FLUSHDB / FLUSHALL takes the flush barrier exclusively so no reader
     * or writer is mid-bucket when we iterate every slot.  All other
     * commands hold the flush barrier in shared (read) mode and contend
     * only for their own bucket's rwlock — the whole point of sharding. */
    if (strcasecmp(cmd, "FLUSHDB") == 0 || strcasecmp(cmd, "FLUSHALL") == 0) {
        pthread_rwlock_wrlock(&s_snap_flush_rwlock);
        for (int b = 0; b < SNAP_BUCKETS; b++) {
            SnapBucket *bk = &s_snap[b];
            for (int i = 0; i < bk->n; i++) bk->entries[i].valid = 0;
        }
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return;
    }

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);

    if ((strcasecmp(cmd, "HSET") == 0 || strcasecmp(cmd, "HMSET") == 0)
            && argc >= 4) {
        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);
        SnapEntry *e = snap_find_or_create_in_bucket(bk, h, key, SNAP_TYPE_HASH);
        if (e)
            for (int i = 2; i + 1 < argc; i += 2)
                snap_set_field(e, argv[i], argv[i+1]);
        pthread_rwlock_unlock(&bk->rwlock);
    } else if (strcasecmp(cmd, "HDEL") == 0 && argc >= 3) {
        /* Tombstone the field so the snapshot doesn't surface stale pairs. */
        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);
        SnapEntry *e = snap_find_in_bucket(bk, h, key);
        if (e && e->type == SNAP_TYPE_HASH) {
            for (int i = 2; i < argc; i++) {
                for (int j = 0; j < e->nfields; j++) {
                    if (strcmp(e->fields[j].f, argv[i]) == 0) {
                        e->fields[j].f[0] = '\0';  /* see hgetall_typed skip */
                        break;
                    }
                }
            }
        }
        pthread_rwlock_unlock(&bk->rwlock);
    } else if (strcasecmp(cmd, "SADD") == 0 && argc >= 3) {
        /* Phase 2 — set add. Each argv[i>=2] is a member; store with an
         * empty value slot so the hash/set reuse of SnapField stays
         * consistent. */
        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);
        SnapEntry *e = snap_find_or_create_in_bucket(bk, h, key, SNAP_TYPE_SET);
        if (e) for (int i = 2; i < argc; i++) snap_set_field(e, argv[i], "");
        pthread_rwlock_unlock(&bk->rwlock);
    } else if (strcasecmp(cmd, "SREM") == 0 && argc >= 3) {
        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);
        SnapEntry *e = snap_find_in_bucket(bk, h, key);
        if (e && e->type == SNAP_TYPE_SET) {
            for (int i = 2; i < argc; i++) {
                for (int j = 0; j < e->nfields; j++) {
                    if (strcmp(e->fields[j].f, argv[i]) == 0) {
                        e->fields[j].f[0] = '\0';
                        break;
                    }
                }
            }
        }
        pthread_rwlock_unlock(&bk->rwlock);
    } else if (strcasecmp(cmd, "ZADD") == 0 && argc >= 4) {
        /* Phase 2 — sorted set add. argv layout after `ZADD key`:
         *   score member [score member ...]
         * We skip any ZADD options (NX/XX/CH/INCR/GT/LT) — those live
         * right after the key and start with uppercase letters only. */
        int start = 2;
        while (start + 1 < argc) {
            const char *t = argv[start];
            /* A valid score always parses as a number. Bail as soon as
             * parsing fails — means we hit the first `member`. */
            char *endp = NULL;
            (void)strtod(t, &endp);
            if (endp != t && *endp == '\0') break;
            start++;  /* option token — skip */
        }
        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);
        SnapEntry *e = snap_find_or_create_in_bucket(bk, h, key, SNAP_TYPE_ZSET);
        if (e) {
            for (int i = start; i + 1 < argc; i += 2) {
                const char *score  = argv[i];
                const char *member = argv[i + 1];
                /* member stored in f, score stored in v */
                snap_set_field(e, member, score);
            }
        }
        pthread_rwlock_unlock(&bk->rwlock);
    } else if (strcasecmp(cmd, "ZREM") == 0 && argc >= 3) {
        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);
        SnapEntry *e = snap_find_in_bucket(bk, h, key);
        if (e && e->type == SNAP_TYPE_ZSET) {
            for (int i = 2; i < argc; i++) {
                for (int j = 0; j < e->nfields; j++) {
                    if (strcmp(e->fields[j].f, argv[i]) == 0) {
                        e->fields[j].f[0] = '\0';
                        break;
                    }
                }
            }
        }
        pthread_rwlock_unlock(&bk->rwlock);
    } else if (strcasecmp(cmd, "SET") == 0 && argc >= 3) {
        /* Phase 2 — string set. Only the simple form (no EX/PX/XX/NX)
         * hits the snapshot. Anything fancier just falls through to the
         * pipe; the mirror's "best effort" contract allows misses. */
        if (argc == 3) {
            uint32_t    h  = snap_key_hash(key);
            SnapBucket *bk = snap_bucket_for_hash(h);
            pthread_rwlock_wrlock(&bk->rwlock);
            SnapEntry *e = snap_find_or_create_in_bucket(bk, h, key, SNAP_TYPE_STRING);
            if (e) {
                e->nfields = 0;          /* fresh — overwrite semantics */
                snap_set_field(e, "", argv[2]);
            }
            pthread_rwlock_unlock(&bk->rwlock);
        }
    } else if ((strcasecmp(cmd, "HINCRBY") == 0 ||
                strcasecmp(cmd, "HINCRBYFLOAT") == 0) && argc == 4) {
        char nbuf[SNAP_VAL_LEN];
        const char *nval = parse_incr_reply(reply, nbuf, sizeof nbuf);
        if (nval) {
            uint32_t    h  = snap_key_hash(key);
            SnapBucket *bk = snap_bucket_for_hash(h);
            pthread_rwlock_wrlock(&bk->rwlock);
            SnapEntry *e = snap_find_or_create_in_bucket(bk, h, key, SNAP_TYPE_HASH);
            if (e) snap_set_field(e, argv[2], nval);
            pthread_rwlock_unlock(&bk->rwlock);
        }
    } else if (strcasecmp(cmd, "DEL") == 0 || strcasecmp(cmd, "UNLINK") == 0) {
        for (int k = 1; k < argc; k++) {
            if (!argv[k]) continue;
            uint32_t    h  = snap_key_hash(argv[k]);
            SnapBucket *bk = snap_bucket_for_hash(h);
            pthread_rwlock_wrlock(&bk->rwlock);
            SnapEntry *e = snap_find_in_bucket(bk, h, argv[k]);
            if (e) e->valid = 0;
            /* Also clear any poisoned slot for this key — DEL means the
             * RESP side has no data either, so we can start fresh on the
             * next SET/HSET/ZADD and re-enter the fast path. */
            for (int i = 0; i < bk->n; i++) {
                SnapEntry *p = &bk->entries[i];
                if (p->poisoned && p->key_hash == h &&
                    strcmp(p->key, argv[k]) == 0) {
                    p->poisoned = 0;
                    p->nfields  = 0;
                }
            }
            pthread_rwlock_unlock(&bk->rwlock);
        }
    }

    pthread_rwlock_unlock(&s_snap_flush_rwlock);
}

/* ---------- Plan 09 auto-mirror (post-EVAL snapshot refresh) -------- *
 * Lua scripts execute their writes via Valkey's call() path, which      *
 * does NOT fire dazzle_snapshot_mirror_write.  For backends that read   *
 * snapshot hash fields populated by Lua (e.g. dazzle-incremental), the  *
 * read path then falls through to the slow pipe HMGET on every call.   *
 *                                                                        *
 * This helper walks the declared KEYS of an EVAL/EVALSHA reply and,     *
 * for each hash-typed key, re-reads its fields via the Valkey hash     *
 * iterator and upserts them into the snapshot cache.  Called from the  *
 * command handlers while the EVAL's per-key stripe wrlocks are still   *
 * held, so no reader can observe a mid-refresh state.                   *
 *                                                                        *
 * Performance: one stack-allocated hashTypeIterator + one iteration    *
 * per declared key.  For the incremental backend's 4 KEYS that is ~15  *
 * µs, cheaper than a cross-FFI HMSET from Kotlin.                       *
 * -------------------------------------------------------------------- */
void dazzle_snapshot_auto_mirror_eval(int argc, const char *const *argv) {
    if (!argv || !argv[0] || argc < 3) return;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return;
    if (strcasecmp(argv[0], "EVAL") != 0 &&
        strcasecmp(argv[0], "EVALSHA") != 0) return;

    char *endp = NULL;
    long numkeys = strtol(argv[2], &endp, 10);
    if (numkeys <= 0) return;
    if ((long)argc < 3 + numkeys) return;

    /* s_fake is always non-NULL at this point (call() cannot have succeeded
     * without it) and s_fake->db was set by selectDb on fake-client init.
     * Passing it to dbFind keeps us on Valkey's normal lookup context
     * rather than poking the global server.db[] layout directly. */
    if (!s_fake || !s_fake->db) return;

    pthread_once(&s_snap_once, snap_init_buckets);
    pthread_rwlock_rdlock(&s_snap_flush_rwlock);

    for (long i = 0; i < numkeys; i++) {
        const char *key = argv[3 + i];
        if (!key || !*key) continue;

        /* dbFind is the minimal lookup API: no refcount, LFU/LRU touch,
         * keyspace-miss notification, or stats increment — all of which
         * assume a live client context that is not set up here. */
        sds ksds = sdsnewlen(key, strlen(key));
        robj *val = dbFind(s_fake->db, ksds);
        sdsfree(ksds);
        if (!val || val->type != OBJ_HASH) continue;

        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);
        pthread_rwlock_wrlock(&bk->rwlock);

        SnapEntry *e = snap_find_or_create_in_bucket(bk, h, key, SNAP_TYPE_HASH);
        if (e) {
            /* Clear then repopulate — stale fields (e.g. HDEL'd inside Lua)
             * disappear from the snapshot.  snap_set_field caps at
             * SNAP_MAX_FIELDS; overflow silently drops like the write path. */
            e->nfields = 0;

            hashTypeIterator hi;
            hashTypeInitIterator(val, &hi);
            while (hashTypeNext(&hi) != C_ERR) {
                sds field = hashTypeCurrentObjectNewSds(&hi, OBJ_HASH_FIELD);
                sds value = hashTypeCurrentObjectNewSds(&hi, OBJ_HASH_VALUE);
                if (field && value) snap_set_field(e, field, value);
                if (field) sdsfree(field);
                if (value) sdsfree(value);
            }
            hashTypeResetIterator(&hi);
        }

        pthread_rwlock_unlock(&bk->rwlock);
    }

    pthread_rwlock_unlock(&s_snap_flush_rwlock);
}

/* ---------- reply extraction ---------------------------------------- */

/* Copy the RESP response from the fake client's output buffers into a
 * freshly allocated, null-terminated C string.
 * Most replies fit entirely in c->buf (PROTO_REPLY_CHUNK_BYTES = 16 KB).
 * Large multi-bulk replies (e.g. KEYS * on a huge keyspace) spill into
 * the c->reply linked list of clientReplyBlock nodes. */
static char *extract_reply(client *c) {
    if (c->bufpos == 0 && listLength(c->reply) == 0)
        return strdup("+OK\r\n");

    size_t total = c->bufpos;
    listIter li;
    listNode *ln;
    listRewind(c->reply, &li);
    while ((ln = listNext(&li)) != NULL) {
        clientReplyBlock *b = listNodeValue(ln);
        total += b->used;
    }

    char *out = malloc(total + 1);
    if (!out) return strdup("-ERR out of memory\r\n");

    memcpy(out, c->buf, c->bufpos);
    size_t off = c->bufpos;
    listRewind(c->reply, &li);
    while ((ln = listNext(&li)) != NULL) {
        clientReplyBlock *b = listNodeValue(ln);
        memcpy(out + off, b->buf, b->used);
        off += b->used;
    }
    out[off] = '\0';
    return out;
}

/* Clear the output buffers so the fake client is ready for the next call.
 * resetClient() (called before this) handles input state (argv, cmd flags).
 * We must clear the output side manually. */
static void clear_reply(client *c) {
    c->bufpos    = 0;
    c->reply_bytes = 0;
    if (listLength(c->reply)) {
        listSetFreeMethod(c->reply, freeClientReplyValue);
        listEmpty(c->reply);
        listSetFreeMethod(c->reply, NULL);
    }
}

/* ---------- event loop handler (runs on the server/event-loop thread) -- */

static void directCommandHandler(aeEventLoop *el, int fd,
                                  void *privdata, int mask) {
    (void)el; (void)privdata; (void)mask;

    DirectRequest *req = NULL;
    if (read(fd, &req, sizeof req) != (ssize_t)sizeof req || !req) return;

    /* Plan 02: try the worker pool before touching main-thread state.
     * On hit, the worker takes ownership of the request — we must NOT
     * fall through to the shared fake client or signal done here. */
    if (try_offload_to_worker(req)) return;

    /* Plan 02 / Stage 2: anything that reaches the main-thread path still
     * races against workers on the same slot.  Three classes of commands:
     *
     *   - Whitelisted read  → global rdlock + slot rdlock (concurrent with
     *     every other worker and main-thread whitelisted op).
     *   - Whitelisted write → global rdlock + slot wrlock (exclusive on the
     *     stripe, concurrent with other stripes).
     *   - Non-whitelisted   → global WRLOCK, no slot lock.  This blocks
     *     every worker regardless of slot because argv[1] does not describe
     *     the keyspace footprint (EVAL / EVALSHA / DEBUG / FLUSHDB / ...).
     *
     * Without the third branch, e.g. an EVALSHA whose Lua body HSETs a
     * key read concurrently by a worker on a different stripe produces
     * a torn reply (observed on `dazzle-incremental` K=8: the worker's
     * HMGET reply buffer truncates mid-response because the hash changes
     * shape while hashTypeGetValue iterates it). */
    int          slot_locked     = 0;
    int          slot_is_write   = 0;
    int          global_held     = 0;
    uint32_t     locked_slot     = 0;
    uint32_t     eval_slots[DAZZLE_MAX_EVAL_KEYS];
    int          eval_n_locked   = 0;
    const char  *cmd0 = (req->argc > 0) ? req->argv_strs[0] : NULL;
    if (dwp_enabled() && cmd0) {
        int is_safe_read  = dazzle_slot_safe_cmd(cmd0);
        int is_safe_write = dazzle_slot_safe_write_cmd(cmd0);
        if (!is_safe_read && !is_safe_write) {
            /* Plan 09: for EVAL / EVALSHA with a valid numkeys > 0, take
             * wrlocks on each declared stripe instead of the global_wrlock.
             * The Lua scripts in the Dazzle benchmarks (incremental +
             * precompute ingest) only touch keys declared in KEYS, which
             * is the Redis/Valkey convention. */
            int eval_nkeys = 0;
            int used_multi = 0;
            if (dwp_eval_key_locks_enabled() &&
                dazzle_eval_extract_slots(req->argc, req->argv_strs,
                                          eval_slots, &eval_nkeys)) {
                dwp_global_rdlock();
                global_held   = 1;
                eval_n_locked = dwp_multi_slot_wrlock(eval_slots, eval_nkeys);
                slot_is_write = 1;
                used_multi    = 1;
            }
            if (!used_multi) {
                dwp_global_wrlock();
                global_held   = 1;
                slot_is_write = 1;   /* treat as "mutation" for snapshot mirror decision */
            }
        } else {
            dwp_global_rdlock();
            global_held   = 1;
            locked_slot   = req->slot;
            slot_is_write = is_safe_write;
            if (slot_is_write) dwp_slot_wrlock(locked_slot);
            else               dwp_slot_rdlock(locked_slot);
            slot_locked = 1;
        }
    }

    /* Lazy-allocate the reusable fake client on the first call. */
    if (!s_fake) {
        s_fake = createClient(NULL);
        if (!s_fake) {
            req->result = strdup("-ERR createClient failed\r\n");
            goto done;
        }
        /* CRITICAL for Valkey 8+: our fake client must mimic
         * createCachedResponseClient() (networking.c) or `prepareClientToWrite`
         * will skip every addReply call and leave the output buffer empty.
         * Two invariants are required:
         *
         *   1. c->id == CLIENT_ID_CACHED_RESPONSE — networking.c line 458 skips
         *      every `flag.fake` client whose id is anything else.
         *   2. c->conn != NULL — line 459 has a `serverAssert(c->conn)` right
         *      after the id check; Valkey 8 expects even fake clients to own
         *      a stub connection struct. We allocate a zeroed one here and
         *      let Valkey free it via the normal client cleanup path (but we
         *      never destroy this client — it lives for the process lifetime).
         *
         * Without BOTH of these, directCommand returns "+OK\r\n" for every
         * call (the extract_reply fallback that fires on an empty buffer).
         * Investigation notes and reproduction are in the refactor commit. */
        s_fake->id = CLIENT_ID_CACHED_RESPONSE;
        s_fake->conn = zcalloc(sizeof(connection));
        s_fake->flag.fake          = 1;   /* no network connection       */
        s_fake->flag.deny_blocking = 1;   /* commands must not block     */
        s_fake->flag.authenticated = 1;   /* trusted in-process caller   */
        /* See create_worker_client() in dazzle_worker_pool.c for the full
         * Blocker D write-up.  Preset pending_write so addReply*() never
         * links us into the unlocked global server.clients_pending_write
         * list — the worker pool needs that list kept clean while its
         * fake clients run concurrent addReply paths. */
        s_fake->flag.pending_write = 1;
        s_fake->resp = 2;

        /* Pre-populate peerid / sockname with placeholder sds strings so
         * Valkey's commandlog / slowlog paths never call genClientAddrString,
         * which dereferences conn->type and crashes because our zeroed
         * connection struct has a NULL function-pointer table. See the
         * SIGSEGV trace in call → commandlogPushCurrentCommand →
         * getClientPeerId → connFormatAddr. */
        s_fake->peerid   = sdsnew("directcmd:0");
        s_fake->sockname = sdsnew("directcmd:0");

        selectDb(s_fake, 0);
    }

    /* Build robj** argv from plain C strings provided by the caller. */
    robj **argv = zmalloc(req->argc * sizeof(robj *));
    for (int i = 0; i < req->argc; i++)
        argv[i] = createStringObject(req->argv_strs[i],
                                     strlen(req->argv_strs[i]));

    s_fake->argc = req->argc;
    s_fake->argv = argv;

    /* Look up the command; execute with AOF + replication propagation. */
    /* Valkey 8.x call() uses cmd (+0x50), lastcmd (+0x58) AND realcmd (+0x60).
     * All three must be set; omitting realcmd causes SIGSEGV in call() at
     * realcmd->flags when logging latency samples. */
    s_fake->cmd = s_fake->lastcmd = s_fake->realcmd = lookupCommand(argv, req->argc);
    if (!s_fake->cmd) {
        addReplyErrorFormat(s_fake, "ERR unknown command '%s'",
                            req->argc > 0 ? (char *)argv[0]->ptr : "");
    } else {
        call(s_fake, CMD_CALL_FULL);
    }

    /* Extract reply BEFORE resetting the client (resetClient frees argv). */
    req->result = extract_reply(s_fake);

    /* Mirror write commands into the HMGET snapshot cache.  Shared helper
     * — workers call the same function so cache stays consistent regardless
     * of which thread executed the write. */
    if (slot_is_write && req->result)
        dazzle_snapshot_mirror_write(req->argc, req->argv_strs, req->result);

    /* Plan 09: post-EVAL auto-mirror.  Lua-internal writes do NOT fire
     * dazzle_snapshot_mirror_write, so we refresh the snapshot entries for
     * the declared KEYS here while still holding the global barrier (and
     * — when parallel reads are enabled — the relevant stripe wrlocks from
     * dwp_global_wrlock on the non-whitelisted branch above). */
    if (req->result && req->argc > 0 &&
        (strcasecmp(req->argv_strs[0], "EVAL") == 0 ||
         strcasecmp(req->argv_strs[0], "EVALSHA") == 0))
        dazzle_snapshot_auto_mirror_eval(req->argc, req->argv_strs);

    /* ── DEBUG: log raw reply for EVAL commands ── */
    #ifdef __ANDROID__
    #include <android/log.h>
    if (req->argc > 0 && strcasecmp(req->argv_strs[0], "EVAL") == 0 && req->result) {
        size_t len = strlen(req->result);
        __android_log_print(ANDROID_LOG_INFO, "EvalDebug",
            "EVAL reply: len=%zu bufpos=%zu reply_list=%lu first_80='%.80s'",
            len, (size_t)s_fake->bufpos, (unsigned long)listLength(s_fake->reply), req->result);
    }
    #endif

    /* resetClient: frees argv, clears command/flag state (input side).
     * clear_reply: zeroes bufpos and empties the reply list (output side). */
    resetClient(s_fake);
    clear_reply(s_fake);

done:
    if (slot_locked)     dwp_slot_unlock(locked_slot);
    if (eval_n_locked)   dwp_multi_slot_unlock(eval_slots, eval_n_locked);
    if (global_held)     dwp_global_unlock();

    req_signal_done(req);
}

/* ---------- Phase 2: ring buffer drain handler (event loop thread) ----- */

#ifdef __ANDROID__
/* Fired by the event loop when the eventfd becomes readable.
 * Drains all pending requests from the ring buffer and processes them
 * exactly like the pipe handler does — but without the pipe read() syscall. */
static void ringDrainHandler(aeEventLoop *el, int fd,
                              void *privdata, int mask) {
    (void)el; (void)privdata; (void)mask;
    ring_drain_eventfd(fd);   /* clear the eventfd counter (1 read syscall) */

    DirectRequest *req;
    while ((req = (DirectRequest *)ring_pop(&s_write_ring)) != NULL) {
        /* Plan 02: offload safe reads and whitelisted writes to workers. */
        if (try_offload_to_worker(req)) continue;

        int         ring_slot_locked   = 0;
        int         ring_is_write      = 0;
        int         ring_global_held   = 0;
        uint32_t    ring_locked_slot   = 0;
        uint32_t    ring_eval_slots[DAZZLE_MAX_EVAL_KEYS];
        int         ring_eval_n_locked = 0;
        const char *ring_cmd0 = (req->argc > 0) ? req->argv_strs[0] : NULL;
        if (dwp_enabled() && ring_cmd0) {
            int is_safe_read  = dazzle_slot_safe_cmd(ring_cmd0);
            int is_safe_write = dazzle_slot_safe_write_cmd(ring_cmd0);
            if (!is_safe_read && !is_safe_write) {
                /* Plan 09: key-aware wrlock path for EVAL / EVALSHA. */
                int eval_nkeys = 0;
                int used_multi = 0;
                if (dwp_eval_key_locks_enabled() &&
                    dazzle_eval_extract_slots(req->argc, req->argv_strs,
                                              ring_eval_slots, &eval_nkeys)) {
                    dwp_global_rdlock();
                    ring_global_held = 1;
                    ring_eval_n_locked = dwp_multi_slot_wrlock(
                        ring_eval_slots, eval_nkeys);
                    ring_is_write = 1;
                    used_multi    = 1;
                }
                if (!used_multi) {
                    dwp_global_wrlock();
                    ring_global_held = 1;
                    ring_is_write    = 1;
                }
            } else {
                dwp_global_rdlock();
                ring_global_held = 1;
                ring_locked_slot = req->slot;
                ring_is_write    = is_safe_write;
                if (ring_is_write) dwp_slot_wrlock(ring_locked_slot);
                else               dwp_slot_rdlock(ring_locked_slot);
                ring_slot_locked = 1;
            }
        }

        /* Identical processing to directCommandHandler — reuse fake client. */
        if (!s_fake) {
            /* Lazy-init: same setup as in directCommandHandler */
            s_fake = createClient(NULL);
            if (!s_fake) {
                req->result = strdup("-ERR createClient failed\r\n");
                goto ring_done;
            }
            s_fake->id = CLIENT_ID_CACHED_RESPONSE;
            s_fake->conn = zcalloc(sizeof(connection));
            s_fake->flag.fake          = 1;
            s_fake->flag.deny_blocking = 1;
            s_fake->flag.authenticated = 1;
            /* See create_worker_client(): skip the unlocked global pending
             * write list to eliminate the worker/main-thread race. */
            s_fake->flag.pending_write = 1;
            s_fake->resp = 2;
            s_fake->peerid   = sdsnew("ringcmd:0");
            s_fake->sockname = sdsnew("ringcmd:0");
            selectDb(s_fake, 0);
        }

        robj **argv = zmalloc(req->argc * sizeof(robj *));
        for (int i = 0; i < req->argc; i++)
            argv[i] = createStringObject(req->argv_strs[i],
                                         strlen(req->argv_strs[i]));

        s_fake->argc = req->argc;
        s_fake->argv = argv;
        s_fake->cmd  = s_fake->lastcmd = s_fake->realcmd =
            lookupCommand(argv, req->argc);

        if (!s_fake->cmd)
            addReplyErrorFormat(s_fake, "ERR unknown command '%s'",
                                req->argc > 0 ? (char *)argv[0]->ptr : "");
        else
            call(s_fake, CMD_CALL_FULL);

        req->result = extract_reply(s_fake);

        if (ring_is_write && req->result)
            dazzle_snapshot_mirror_write(req->argc, req->argv_strs, req->result);

        /* Plan 09: auto-mirror post-EVAL (see directCommandHandler). */
        if (req->result && req->argc > 0 &&
            (strcasecmp(req->argv_strs[0], "EVAL") == 0 ||
             strcasecmp(req->argv_strs[0], "EVALSHA") == 0))
            dazzle_snapshot_auto_mirror_eval(req->argc, req->argv_strs);

        resetClient(s_fake);
        clear_reply(s_fake);

ring_done:
        if (ring_slot_locked)   dwp_slot_unlock(ring_locked_slot);
        if (ring_eval_n_locked) dwp_multi_slot_unlock(ring_eval_slots,
                                                      ring_eval_n_locked);
        if (ring_global_held)   dwp_global_unlock();

        req_signal_done(req);
    }
}
#endif /* __ANDROID__ */

/* ---------- init (called from server.c patch, on the server thread) --- */

void dazzle_direct_init(void) {
    if (s_pipe[0] != -1) return;   /* idempotent */

    /* Plan 08: pick up the ablation env vars on every fresh server start.
     * Called before dwp_init so mode flips during a sweep take effect on
     * the next cell the same way DAZZLE_PARALLEL_READS does. */
    dazzle_snapshot_reload_config();

    /* Plan 02: spawn worker pool before wiring any event-loop file events.
     * Runs in shadow mode until DAZZLE_PARALLEL_READS=1 + the thread-local
     * current_client patch is applied.  Failure is non-fatal. */
    (void)dwp_init();

#ifdef __ANDROID__
    /* Phase 2: try the ring buffer path first. */
    ring_init(&s_write_ring);
    s_ring_efd = ring_eventfd_create();
    if (s_ring_efd != -1) {
        if (aeCreateFileEvent(server.el, s_ring_efd, AE_READABLE,
                              ringDrainHandler, NULL) == AE_OK) {
            atomic_store(&s_ring_active, 1);
            /* Phase 3: try io_uring on top of the ring for batch pipeline. */
            if (uring_available() && uring_init(&s_uring))
                atomic_store(&s_uring_active, 1);
            /* Pipe is still created as a fallback for ring-full conditions. */
        } else {
            close(s_ring_efd);
            s_ring_efd = -1;
        }
    }
#endif

    if (pipe(s_pipe) != 0) return;

    /* Register the read end with Valkey's event loop.  Safe here because
     * we ARE on the server thread (called between InitServerLast and aeMain). */
    if (aeCreateFileEvent(server.el, s_pipe[0], AE_READABLE,
                          directCommandHandler, NULL) == AE_ERR) {
        close(s_pipe[0]); close(s_pipe[1]);
        s_pipe[0] = s_pipe[1] = -1;
    }
}

/* ---------- public API (called from dazzle_ios.c / dazzle_jni.c) ------- */

/* Submit a command to the event loop thread and wait for the result.
 * Returns a heap-allocated, null-terminated RESP string.
 * Caller must free() the result (or call dazzle_direct_free).
 *
 * Phase 2: on Android, tries the ring buffer + eventfd path first.
 * Falls back to the OS pipe if the ring is full or unavailable. */
char *dazzle_direct_command(int argc, const char **argv_strs) {
    if (argc <= 0 || !argv_strs) return NULL;

    DirectRequest req;
    req.argc      = argc;
    req.argv_strs = argv_strs;
    req.slot      = (argc >= 2 && argv_strs[1])
        ? dwp_key_slot(argv_strs[1], (int)strlen(argv_strs[1]))
        : 0;
    req_init(&req);

    DirectRequest *reqp = &req;

    /* Direct-to-worker fast path: safe read commands skip the ring +
     * eventfd + single-threaded event-loop dispatcher entirely, pushing
     * straight into the selected worker's queue.  Removes the event loop
     * as a serialization point — under K=N concurrent agents the worker
     * pool can now accept pushes from N producers in parallel
     * (queue_push is MPSC, serialized per-worker via push_mtx).
     *
     * Writes + unclassified commands still route through the ring so
     * the main-thread snapshot mirror remains the single writer. */
    if (dwp_enabled() && argv_strs[0] &&
        dazzle_slot_safe_cmd(argv_strs[0]) &&
        dwp_enqueue(reqp) == 0) {
        req_wait(&req);
        char *r = req.result;
        req_destroy(&req);
        return r;
    }

#ifdef __ANDROID__
    /* Phase 2 fast path: push to ring buffer, wake with eventfd (1 syscall). */
    if (atomic_load_explicit(&s_ring_active, memory_order_relaxed) &&
            ring_push(&s_write_ring, reqp)) {
        ring_notify(s_ring_efd);   /* ~5 µs vs ~50 µs pipe write */
        req_wait(&req);
        char *r = req.result;
        req_destroy(&req);
        return r;
    }
    /* Fall through to pipe path if ring is full or not yet active. */
#endif

    /* Original pipe path (iOS + Android fallback). write(8 bytes) is atomic
     * per POSIX on blocking pipes ≤ PIPE_BUF, so no write-side lock needed. */
    if (s_pipe[1] == -1) {
        req_destroy(&req);
        return NULL;
    }
    if (write(s_pipe[1], &reqp, sizeof reqp) != (ssize_t)sizeof reqp) {
        req_destroy(&req);
        return NULL;
    }
    req_wait(&req);
    char *r = req.result;
    req_destroy(&req);
    return r;
}

void dazzle_direct_free(char *result) {
    free(result);
}

/* ── Phase 3: batch pipeline dispatch ──────────────────────────────────── *
 * Push N requests to the ring buffer then wake the event loop ONCE via     *
 * io_uring (1 syscall) instead of N eventfd writes.                        *
 *                                                                           *
 * Complexity comparison for a 6-command ingest pipeline:                   *
 *   Phase 0 (pipe):        6 × write() + 6 × read() = 12 syscalls          *
 *   Phase 2 (ring+eventfd): 6 × ring_push + 6 × eventfd_write = 6 syscalls *
 *   Phase 3 (ring+uring):  6 × ring_push + 1 × io_uring_submit = 1 syscall *
 *                                                                           *
 * Falls back to Phase 2 (N eventfd writes) on devices without io_uring,    *
 * and to Phase 0 (pipe) if the ring is full.                               *
 *                                                                           *
 * Called from nativeDirectPipeline (dazzle_jni.c).  reqs[] must already    *
 * be allocated and initialized; this function owns them until done==1.      *
 * ──────────────────────────────────────────────────────────────────────── */
#ifdef __ANDROID__
void dazzle_pipeline_dispatch(DirectRequest **reqs, int n) {
    if (n <= 0) return;

    int ring_ok  = atomic_load_explicit(&s_ring_active,  memory_order_relaxed);
    int uring_ok = atomic_load_explicit(&s_uring_active, memory_order_relaxed);

    if (ring_ok) {
        /* Push all N to ring buffer (lock-free, 0 syscalls) */
        int pushed = 0;
        for (int i = 0; i < n; i++) {
            if (ring_push(&s_write_ring, reqs[i]))
                pushed++;
            else {
                /* Ring full — fall back to pipe for this request.
                 * write(8 bytes) is POSIX-atomic on blocking pipes. */
                if (s_pipe[1] != -1 &&
                    write(s_pipe[1], &reqs[i], sizeof reqs[i])
                        == (ssize_t)sizeof reqs[i]) {
                    /* dispatched; worker will signal cv */
                } else {
                    req_signal_done(reqs[i]);   /* unblock the waiter */
                }
            }
        }

        if (pushed > 0) {
            if (uring_ok) {
                /* Phase 3: 1 io_uring_submit for ALL pushed commands */
                uring_batch_notify(&s_uring, s_ring_efd, pushed);
                /* Drain CQ to prevent overflow (fire-and-forget writes) */
                uring_drain_cq(&s_uring);
            } else {
                /* Phase 2 fallback: one eventfd write per pushed command */
                for (int i = 0; i < pushed; i++)
                    ring_notify(s_ring_efd);
            }
        }
    } else {
        /* Phase 0 fallback: pipe, one at a time */
        for (int i = 0; i < n; i++) {
            if (s_pipe[1] != -1 &&
                write(s_pipe[1], &reqs[i], sizeof reqs[i])
                    == (ssize_t)sizeof reqs[i]) {
                /* dispatched */
            } else {
                req_signal_done(reqs[i]);
            }
        }
    }
}
#endif /* __ANDROID__ */

/* ── Public helper: wait for a dispatched pipeline request ─────────────── *
 * Encapsulates the pthread_cond_wait loop so dazzle_jni.c does not need    *
 * direct access to the per-request mtx/cv of DirectRequest.               *
 *                                                                           *
 * Called once per command after dazzle_pipeline_dispatch() returns.  *
 * Blocks the calling thread until the event loop has written req->result.  *
 * ─────────────────────────────────────────────────────────────────────────*/
void dazzle_wait_result(void *req_ptr) {
    DirectRequest *req = (DirectRequest *)req_ptr;
    req_wait(req);
}

/* ── Phase 5 (partial) — typed JNI return ──────────────────────────────── *
 * Returns a Java String[] by reading field values directly from the snapshot *
 * cache, bypassing RESP serialisation completely.                             *
 *                                                                             *
 * Called from nativeDirectReadFields (dazzle_jni.c) with JNIEnv already set. *
 * Returns NULL if the key is not in the snapshot — JNI layer falls back to   *
 * the RESP path (nativeDirectRead → pipe).                                   *
 * ─────────────────────────────────────────────────────────────────────────── */
#ifdef __ANDROID__
#include <jni.h>

jobjectArray valkey_snapshot_hmget_typed(
        JNIEnv *env, jclass strCls, const char *key,
        int nfields, const char **fields) {
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return NULL;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_HASH) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return NULL;   /* not cached or wrong type → fall back to pipe */
    }

    /* Build Java String[nfields] directly from snapshot values. */
    jobjectArray out = (*env)->NewObjectArray(env, nfields, strCls, NULL);

    int n = nfields < SNAP_MAX_FIELDS ? nfields : SNAP_MAX_FIELDS;
    for (int i = 0; i < n; i++) {
        const char *val = NULL;
        for (int j = 0; j < e->nfields; j++) {
            if (strcmp(e->fields[j].f, fields[i]) == 0) {
                val = e->fields[j].v;
                break;
            }
        }
        if (val) {
            jstring jval = (*env)->NewStringUTF(env, val);
            (*env)->SetObjectArrayElement(env, out, i, jval);
            (*env)->DeleteLocalRef(env, jval);
        }
        /* else: slot stays NULL — field not found in snapshot */
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return out;   /* caller owns the reference */
}
#endif /* __ANDROID__ */

/* Single-field snapshot read. JNI-independent so it works on Darwin too.
 * Copies the field value into out[cap]; returns the byte length written
 * (excluding NUL), or -1 on miss. Called from both the Android JNI single-
 * field path and the iOS FFI bridge. */
int valkey_snapshot_hget_typed(const char *key, const char *field,
                               char *out, int cap) {
    if (!key || !field || !out || cap <= 0) return -1;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return -1;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_HASH) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return -1;
    }

    int n = -1;
    for (int j = 0; j < e->nfields; j++) {
        if (strcmp(e->fields[j].f, field) == 0) {
            size_t len = strlen(e->fields[j].v);
            if ((int)len >= cap) len = (size_t)cap - 1;
            memcpy(out, e->fields[j].v, len);
            out[len] = '\0';
            n = (int)len;
            break;
        }
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return n;   /* -1 if field absent */
}

/* Phase 1 — directRead: answer HMGET from the snapshot cache.
 *
 * Called from the APP THREAD.  Never touches any Valkey internal (no
 * dbFind, no sds, no zmalloc) — only reads the snapshot under rdlock.
 *
 * Returns a heap-allocated RESP array string on hit; NULL on miss
 * (unknown key, unsupported command) so the caller falls back to pipe.
 *
 * Expected latency: ~150 µs (vs 948 µs via pipe) — eliminates the two
 * kernel context-switches that dominate the pipe path (see PHASE_1_INVESTIGATION.md).
 */
char *dazzle_direct_read(int argc, const char **argv) {
    /* Only handle HMGET key f1 [f2 ...] */
    if (argc < 3 || strcasecmp(argv[0], "HMGET") != 0) return NULL;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return NULL;
    pthread_once(&s_snap_once, snap_init_buckets);

    const char  *key    = argv[1];
    int          nf     = argc - 2;
    const char **fields = argv + 2;

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_HASH) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return NULL;   /* key not yet cached or wrong type → fall back to pipe */
    }

    /* ── Build RESP array: *N\r\n + per field: $len\r\nval\r\n OR $-1\r\n ── */

    /* First pass: resolve field pointers and compute total buffer size. */
    const char *vals[SNAP_MAX_FIELDS];
    int         vlens[SNAP_MAX_FIELDS];
    char        hdr[32];
    int         hdrlen = snprintf(hdr, sizeof hdr, "*%d\r\n", nf);
    size_t      total  = (size_t)hdrlen;
    char        tmp[32];

    int n = nf < SNAP_MAX_FIELDS ? nf : SNAP_MAX_FIELDS;
    for (int i = 0; i < n; i++) {
        vals[i] = NULL;
        for (int j = 0; j < e->nfields; j++) {
            if (strcmp(e->fields[j].f, fields[i]) == 0) {
                vals[i] = e->fields[j].v;
                break;
            }
        }
        if (vals[i]) {
            vlens[i] = (int)strlen(vals[i]);
            total += (size_t)snprintf(tmp, sizeof tmp, "$%zu\r\n", (size_t)vlens[i])
                   + (size_t)vlens[i] + 2;   /* value + \r\n */
        } else {
            total += 5;   /* "$-1\r\n" */
        }
    }

    char *out = malloc(total + 1);
    if (!out) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return NULL;
    }

    /* Second pass: fill the buffer. */
    memcpy(out, hdr, hdrlen);
    size_t off = (size_t)hdrlen;
    for (int i = 0; i < n; i++) {
        if (vals[i]) {
            off += (size_t)snprintf(out + off, total - off + 1, "$%zu\r\n", (size_t)vlens[i]);
            memcpy(out + off, vals[i], vlens[i]);
            off += (size_t)vlens[i];
            out[off++] = '\r'; out[off++] = '\n';
        } else {
            memcpy(out + off, "$-1\r\n", 5);
            off += 5;
        }
    }
    out[off] = '\0';

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return out;   /* caller must free() */
}

/* ── Phase 5 — typed snapshot read for iOS / any non-JNI caller ────────── *
 * Same semantics as dazzle_direct_read but returns an array of heap-alloc  *
 * null-terminated values without the RESP envelope.  Avoids the RESP       *
 * serialise + parse round-trip that is ~30-80 µs per call on iOS.          *
 *                                                                           *
 * out[] must have at least nfields entries. On hit returns 1 and fills     *
 * out[i] with either a malloc'd value string or NULL (field absent). On    *
 * miss returns 0 and leaves out[] untouched; caller should fall back to    *
 * the pipe path.                                                            *
 *                                                                           *
 * Caller frees each non-null out[i] with free() (or dazzle_direct_free).   *
 * ───────────────────────────────────────────────────────────────────────── */
int dazzle_snapshot_hmget(const char *key, int nfields,
                          const char **fields, char **out) {
    if (!key || nfields <= 0 || !fields || !out) return 0;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return 0;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_HASH) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return 0;   /* miss or wrong type → caller falls back to pipe */
    }

    int n = nfields < SNAP_MAX_FIELDS ? nfields : SNAP_MAX_FIELDS;
    for (int i = 0; i < n; i++) {
        out[i] = NULL;
        for (int j = 0; j < e->nfields; j++) {
            if (strcmp(e->fields[j].f, fields[i]) == 0) {
                /* strdup while still holding the rdlock so the source bytes
                 * are stable. zmalloc is not available here, use malloc. */
                size_t L = strlen(e->fields[j].v);
                char  *copy = (char *)malloc(L + 1);
                if (copy) {
                    memcpy(copy, e->fields[j].v, L + 1);
                    out[i] = copy;
                }
                break;
            }
        }
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return 1;
}

/* ── Phase 7 — typed HGETALL without RESP ──────────────────────────────── *
 * Read EVERY field stored for `key` in the snapshot. Caller does not know   *
 * the field set in advance (that's HMGET's contract, not HGETALL's), so    *
 * we copy pairs out into two parallel arrays the caller pre-allocated.      *
 *                                                                           *
 * Returns:                                                                  *
 *   >= 0  : number of field/value pairs written to out_fields / out_values *
 *   -1    : snapshot miss (key not cached) — caller falls back to pipe     *
 *                                                                           *
 * Ownership: every non-NULL slot in out_fields and out_values is a         *
 * malloc'd NUL-terminated string. Caller frees each with free() (or       *
 * valkey_direct_free). Non-populated slots stay untouched.                 *
 *                                                                           *
 * Rationale: ContextStore.get() today calls HashKey.getAll() which runs    *
 * HGETALL through the pipe + RESP + RespParser path. That generated a     *
 * measurable regression vs the pre-refactor baseline that used to win     *
 * against ObjectBox / SQLite-vector-ai. Since Dazzle is embedded and      *
 * nobody outside the SDK sees RESP, the text encode + decode cycle is     *
 * pure waste when the data is already hot in the snapshot cache.          *
 * ──────────────────────────────────────────────────────────────────────── */
int dazzle_snapshot_hgetall_typed(const char *key,
                                  char      **out_fields,
                                  char      **out_values,
                                  int         max_pairs) {
    if (!key || !out_fields || !out_values || max_pairs <= 0) return -1;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return -1;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_HASH) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return -1;  /* miss or wrong type → caller falls back to pipe */
    }

    int n = e->nfields < max_pairs ? e->nfields : max_pairs;
    int written = 0;
    for (int j = 0; j < n; j++) {
        /* Skip tombstoned fields — snap_set_field marks deletes with an
         * empty f[] name so we don't surface stale pairs. */
        if (e->fields[j].f[0] == '\0') continue;

        size_t lf = strlen(e->fields[j].f);
        size_t lv = strlen(e->fields[j].v);
        char  *cf = (char *)malloc(lf + 1);
        char  *cv = (char *)malloc(lv + 1);
        if (!cf || !cv) {
            /* Partial OOM — free what we just allocated, stop cleanly. */
            if (cf) free(cf);
            if (cv) free(cv);
            break;
        }
        memcpy(cf, e->fields[j].f, lf + 1);
        memcpy(cv, e->fields[j].v, lv + 1);
        out_fields[written] = cf;
        out_values[written] = cv;
        written++;
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return written;
}

/* ══════════════════════════════════════════════════════════════════════ *
 * Phase 2 — typed readers for non-hash primitives                        *
 *                                                                         *
 * Same contract as dazzle_snapshot_hgetall_typed: returns the number of   *
 * entries written to the caller's buffer, or -1 on a snapshot miss /     *
 * wrong-type mismatch so the Kotlin/Swift side can fall back to the pipe.*
 * Every non-NULL slot is a malloc'd C string the caller must free via    *
 * valkey_direct_free (or plain free()).                                   *
 * ══════════════════════════════════════════════════════════════════════ */

/* Set members — equivalent to SMEMBERS but never touches Valkey's event
 * loop. Useful for tag indexes in ContextStore.byTag / byTags. */
int dazzle_snapshot_smembers_typed(const char *key,
                                   char      **out_members,
                                   int         max_members) {
    if (!key || !out_members || max_members <= 0) return -1;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return -1;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_SET) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return -1;
    }

    int written = 0;
    for (int j = 0; j < e->nfields && written < max_members; j++) {
        if (e->fields[j].f[0] == '\0') continue;   /* tombstone */
        size_t L = strlen(e->fields[j].f);
        char  *copy = (char *)malloc(L + 1);
        if (!copy) break;
        memcpy(copy, e->fields[j].f, L + 1);
        out_members[written++] = copy;
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return written;
}

/* Sorted set full range (equivalent to ZRANGE key 0 -1 [WITHSCORES=0]).
 * The snapshot stores zset members in insertion order — not score order
 * — so callers that need score-ordered output should use
 * dazzle_snapshot_zrange_by_score_typed instead. Kept for the common
 * "give me every member" query without the score baggage. */
int dazzle_snapshot_zrange_all_typed(const char *key,
                                     char      **out_members,
                                     int         max_members) {
    if (!key || !out_members || max_members <= 0) return -1;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return -1;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_ZSET) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return -1;
    }

    int written = 0;
    for (int j = 0; j < e->nfields && written < max_members; j++) {
        if (e->fields[j].f[0] == '\0') continue;
        size_t L = strlen(e->fields[j].f);
        char  *copy = (char *)malloc(L + 1);
        if (!copy) break;
        memcpy(copy, e->fields[j].f, L + 1);
        out_members[written++] = copy;
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return written;
}

/* Sorted set range by score — emits members whose stored score lies in
 * [min, max] (inclusive). Result order is sorted ascending by score,
 * matching Valkey's ZRANGEBYSCORE default ordering. */
static int zset_cmp_score(const void *a, const void *b) {
    double sa = ((const SnapField *)a)->v[0] ? strtod(((const SnapField *)a)->v, NULL) : 0;
    double sb = ((const SnapField *)b)->v[0] ? strtod(((const SnapField *)b)->v, NULL) : 0;
    if (sa < sb) return -1;
    if (sa > sb) return  1;
    return 0;
}

int dazzle_snapshot_zrange_by_score_typed(const char *key,
                                          double      min_score,
                                          double      max_score,
                                          char      **out_members,
                                          int         max_members) {
    if (!key || !out_members || max_members <= 0) return -1;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return -1;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_ZSET) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return -1;
    }

    /* Collect matching (member, score) pairs into a stack buffer, sort
     * by score, copy out. The 64-pair cap is inherited from
     * SNAP_MAX_FIELDS — any larger zset is by definition not in cache. */
    SnapField matches[SNAP_MAX_FIELDS];
    int nmatch = 0;
    for (int j = 0; j < e->nfields && nmatch < SNAP_MAX_FIELDS; j++) {
        if (e->fields[j].f[0] == '\0') continue;
        double s = strtod(e->fields[j].v, NULL);
        if (s >= min_score && s <= max_score) {
            matches[nmatch++] = e->fields[j];
        }
    }
    qsort(matches, (size_t)nmatch, sizeof(SnapField), zset_cmp_score);

    int written = 0;
    int limit = nmatch < max_members ? nmatch : max_members;
    for (int j = 0; j < limit; j++) {
        size_t L = strlen(matches[j].f);
        char  *copy = (char *)malloc(L + 1);
        if (!copy) break;
        memcpy(copy, matches[j].f, L + 1);
        out_members[written++] = copy;
    }

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return written;
}

/* String GET — writes the value into the caller's buffer and returns the
 * number of bytes written (excluding the NUL terminator). -1 on miss /
 * wrong type. Caller's buffer must be at least `cap` bytes. */
int dazzle_snapshot_get_string_typed(const char *key,
                                     char       *out,
                                     int         cap) {
    if (!key || !out || cap <= 0) return -1;
    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return -1;
    pthread_once(&s_snap_once, snap_init_buckets);

    uint32_t    h  = snap_key_hash(key);
    SnapBucket *bk = snap_bucket_for_hash(h);

    pthread_rwlock_rdlock(&s_snap_flush_rwlock);
    pthread_rwlock_rdlock(&bk->rwlock);

    SnapEntry *e = snap_find_in_bucket(bk, h, key);
    if (!e || e->type != SNAP_TYPE_STRING || e->nfields == 0) {
        pthread_rwlock_unlock(&bk->rwlock);
        pthread_rwlock_unlock(&s_snap_flush_rwlock);
        return -1;
    }

    /* Layout convention for SNAP_TYPE_STRING: fields[0].v is the value. */
    size_t L = strlen(e->fields[0].v);
    if ((int)L >= cap) L = (size_t)cap - 1;
    memcpy(out, e->fields[0].v, L);
    out[L] = '\0';

    pthread_rwlock_unlock(&bk->rwlock);
    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return (int)L;
}

/* ── Phase 6a — multi-key typed snapshot HMGET ─────────────────────────── *
 * Reads nkeys different hash keys with (potentially) different field sets  *
 * under a SINGLE pthread_rwlock_rdlock acquisition.  This amortises both   *
 * the rwlock cost and — more importantly — the FFI/JNI cross at the       *
 * Swift/Kotlin boundary (callers previously paid N crossings).             *
 *                                                                           *
 * Inputs                                                                    *
 *   nkeys          Number of hash keys to read.                            *
 *   keys           nkeys NUL-terminated key strings.                       *
 *   field_counts   nkeys ints; field_counts[k] is the field count for     *
 *                  keys[k].  Entries with field_counts[k] <= 0 are        *
 *                  skipped (contribute 0 slots to fields/out).            *
 *   fields         Flat array of sum(field_counts) NUL-terminated field    *
 *                  names.  Layout: [k0_f0, k0_f1, ..., k1_f0, k1_f1, ...] *
 *   out            Flat output array of sum(field_counts) slots.          *
 *                                                                           *
 * Output semantics                                                          *
 *   out[] is zeroed at entry.  For each key that hits the snapshot, the    *
 *   matching field values are malloc'd and written into the corresponding  *
 *   out slots; absent fields stay NULL.  Slots for missed keys all stay    *
 *   NULL.  Caller must free() each non-NULL out[i].                        *
 *                                                                           *
 * Return value                                                              *
 *   1 if at least one key was found in the snapshot, 0 if all missed       *
 *   (caller should fall back to the pipe path for each missed key).       *
 * ─────────────────────────────────────────────────────────────────────────── */
int dazzle_snapshot_mhmget(int nkeys,
                           const char *const *keys,
                           const int *field_counts,
                           const char **fields,
                           char **out) {
    if (nkeys <= 0 || !keys || !field_counts || !fields || !out) return 0;

    size_t total = 0;
    for (int k = 0; k < nkeys; k++) {
        if (field_counts[k] > 0) total += (size_t)field_counts[k];
    }
    for (size_t i = 0; i < total; i++) out[i] = NULL;

    if (atomic_load_explicit(&s_snap_disabled, memory_order_acquire)) return 0;
    pthread_once(&s_snap_once, snap_init_buckets);
    pthread_rwlock_rdlock(&s_snap_flush_rwlock);

    int any_hit   = 0;
    int field_off = 0;
    for (int k = 0; k < nkeys; k++) {
        int nf = field_counts[k];
        if (nf <= 0) continue;
        const char *key = keys[k];
        if (!key) { field_off += nf; continue; }

        uint32_t    h  = snap_key_hash(key);
        SnapBucket *bk = snap_bucket_for_hash(h);

        pthread_rwlock_rdlock(&bk->rwlock);
        SnapEntry *e = snap_find_in_bucket(bk, h, key);
        if (e && e->type == SNAP_TYPE_HASH) {
            any_hit = 1;
            int n = nf < SNAP_MAX_FIELDS ? nf : SNAP_MAX_FIELDS;
            for (int i = 0; i < n; i++) {
                const char *fld = fields[field_off + i];
                if (!fld) continue;
                for (int j = 0; j < e->nfields; j++) {
                    if (strcmp(e->fields[j].f, fld) == 0) {
                        size_t L = strlen(e->fields[j].v);
                        char  *copy = (char *)malloc(L + 1);
                        if (copy) {
                            memcpy(copy, e->fields[j].v, L + 1);
                            out[field_off + i] = copy;
                        }
                        break;
                    }
                }
            }
            /* Slots for i >= SNAP_MAX_FIELDS stay NULL. */
        }
        pthread_rwlock_unlock(&bk->rwlock);
        field_off += nf;
    }

    pthread_rwlock_unlock(&s_snap_flush_rwlock);
    return any_hit;
}

/* ── Phase 6b — coalesced pipeline dispatch ────────────────────────────── *
 * Execute N commands and return N replies in a single entry-point call.    *
 * The caller side of the FFI/JNI boundary pays exactly one crossing to    *
 * reach this function and one more to collect replies (the existing       *
 * dazzle_pipeline_dispatch already amortises the kernel syscalls).        *
 *                                                                           *
 * Inputs                                                                    *
 *   n          Number of commands.                                         *
 *   argv_lens  n ints; argv_lens[i] is the argc of command i.             *
 *   argv_flat  Flat array of sum(argv_lens) C strings.                    *
 *   replies    n output slots; replies[i] receives a heap-allocated RESP  *
 *              string that the caller must free() (or NULL on failure).   *
 *                                                                           *
 * Return value                                                              *
 *   1 on dispatch, 0 if the transport is not initialised or allocation    *
 *   failed before any command could be queued.                             *
 *                                                                           *
 * Android fast path                                                         *
 *   Builds N heap DirectRequest objects and calls                          *
 *   dazzle_pipeline_dispatch → ring buffer + io_uring batch submit        *
 *   (1 syscall for all N on Android 12+).                                  *
 *                                                                           *
 * iOS / generic path                                                        *
 *   N independent pipe writes (each POSIX-atomic for ≤ PIPE_BUF), then    *
 *   waits each request on its own condvar. No shared mutex.               *
 * ─────────────────────────────────────────────────────────────────────────── */
int dazzle_pipeline_args(int n,
                         const int *argv_lens,
                         const char **argv_flat,
                         char **replies) {
    if (n <= 0 || !argv_lens || !argv_flat || !replies) return 0;

    for (int i = 0; i < n; i++) replies[i] = NULL;

    DirectRequest *reqs = (DirectRequest *)calloc((size_t)n, sizeof(DirectRequest));
    if (!reqs) return 0;

    int off = 0;
    for (int i = 0; i < n; i++) {
        reqs[i].argc      = argv_lens[i];
        reqs[i].argv_strs = argv_flat + off;
        reqs[i].slot      = (argv_lens[i] >= 2 && argv_flat[off + 1])
            ? dwp_key_slot(argv_flat[off + 1],
                           (int)strlen(argv_flat[off + 1]))
            : 0;
        req_init(&reqs[i]);
        off += argv_lens[i];
    }

#ifdef __ANDROID__
    DirectRequest **reqps = (DirectRequest **)malloc((size_t)n * sizeof(DirectRequest *));
    if (!reqps) {
        for (int i = 0; i < n; i++) req_destroy(&reqs[i]);
        free(reqs);
        return 0;
    }
    for (int i = 0; i < n; i++) reqps[i] = &reqs[i];

    dazzle_pipeline_dispatch(reqps, n);
    for (int i = 0; i < n; i++) {
        req_wait(&reqs[i]);
        replies[i] = reqs[i].result;   /* caller frees */
    }
    free(reqps);
#else
    /* iOS / generic: N independent pipe writes (POSIX-atomic per PIPE_BUF),
     * then wait each request on its own cv. No shared mutex needed. */
    if (s_pipe[1] == -1) {
        for (int i = 0; i < n; i++) req_destroy(&reqs[i]);
        free(reqs);
        return 0;
    }
    for (int i = 0; i < n; i++) {
        DirectRequest *p = &reqs[i];
        if (write(s_pipe[1], &p, sizeof p) != (ssize_t)sizeof p)
            req_signal_done(&reqs[i]);   /* dispatch failed — unblock */
    }
    for (int i = 0; i < n; i++) {
        req_wait(&reqs[i]);
        replies[i] = reqs[i].result;
    }
#endif

    for (int i = 0; i < n; i++) req_destroy(&reqs[i]);
    free(reqs);
    return 1;
}

// Keep per-module ValkeyModule_OnLoad_<name> alive through the iOS linker's
// dead-strip pass. Each static module exports a dazzle_<name>_onload_ref
// symbol pointing to its OnLoad; referencing those here creates a chain:
//   Swift → dazzle_transport → dazzle_<name>_onload_ref → OnLoad
// so dlsym(RTLD_DEFAULT, "ValkeyModule_OnLoad_<name>") finds them at runtime.
// Android uses `-Wl,-u,<sym>` directly in CMakeLists (simpler there) — this
// block is iOS-specific because the iOS build assembles the static library
// by hand and the refs under a .o that's guaranteed to be live do the job.
#if defined(VALKEY_IOS) && defined(DAZZLE_VECTORSEARCH)
extern void* dazzle_vectorsearch_onload_ref;
static __attribute__((used)) void* _keep_vs = &dazzle_vectorsearch_onload_ref;
#endif
#if defined(VALKEY_IOS) && defined(DAZZLE_TFI)
extern void* dazzle_tfi_onload_ref;
static __attribute__((used)) void* _keep_tfi = &dazzle_tfi_onload_ref;
#endif

#endif /* VALKEY_IOS || __ANDROID__ */
