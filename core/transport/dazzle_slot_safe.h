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

/* dazzle_slot_safe.h — whitelist of commands eligible for worker offload.
 *
 * A command goes on this list only if ALL three properties hold:
 *   1. Read-only at the server level (CMD_READONLY in Valkey's JSON).
 *   2. Single-shard — the first positional argument is a key, and the
 *      whole operation lives on that one slot (so sticky dispatch wins).
 *   3. Does not need main-thread-only side effects (keyspace notifications,
 *      stats counters that Dazzle doesn't care about, or replication
 *      state).  Anything expired / touched / rehashed goes through the
 *      continuation queue instead.
 *
 * The list is intentionally SHORT in Plan 02.  Expand it in follow-ups
 * once M3 (write barrier) and M4 (continuation queue) are proven safe
 * under fuzzing.
 *
 * Commands that are single-key read but touch expired-key paths (GET of
 * an expired key, HGET of an expired hash) are still safe to offload
 * because the expire-side effect is pushed to the continuation queue.
 */

#ifndef DAZZLE_SLOT_SAFE_H
#define DAZZLE_SLOT_SAFE_H

#if defined(VALKEY_IOS) || defined(__ANDROID__)

#include <string.h>
#include <strings.h>   /* strcasecmp */

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 1 if `cmd` (first argv string) is eligible for worker offload.
 * Case-insensitive.  Runs on the main/event-loop thread in the dispatch
 * hot path, so keep it O(#commands) with early-out — a perfect hash would
 * be premature before the list grows past ~30 entries. */
static inline int dazzle_slot_safe_cmd(const char *cmd) {
    if (!cmd) return 0;
    /* Ordered roughly by expected frequency in Dazzle retrieval workloads
     * so strcasecmp returns early for the common cases. */
    static const char *const SAFE[] = {
        "GET",        "MGET",       "EXISTS",
        "HGET",       "HMGET",      "HGETALL",   "HEXISTS",  "HKEYS",
        "HVALS",      "HLEN",       "HSTRLEN",   "HRANDFIELD",
        "LINDEX",     "LRANGE",     "LLEN",
        "SMEMBERS",   "SISMEMBER",  "SMISMEMBER","SCARD",
        "ZRANGE",     "ZREVRANGE",  "ZRANGEBYSCORE", "ZREVRANGEBYSCORE",
        "ZRANGEBYLEX","ZRANK",      "ZREVRANK",  "ZSCORE",   "ZMSCORE",
        "ZCARD",      "ZCOUNT",     "ZLEXCOUNT",
        "BITCOUNT",   "BITPOS",     "GETBIT",
        "STRLEN",     "GETRANGE",   "SUBSTR",
        "TYPE",       "TTL",        "PTTL",      "OBJECT",
        NULL
    };
    for (const char *const *p = SAFE; *p; p++) {
        if (strcasecmp(cmd, *p) == 0) return 1;
    }
    return 0;
}

/* Returns 1 if `cmd` is a single-key WRITE safe to run on a worker under
 * the slot wrlock.  Narrower than "every write" by design — the worker
 * executes call(c, CMD_CALL_NONE), so commands whose correctness depends
 * on AOF propagation, replication backlog, keyspace notifications, or
 * multi-key atomicity stay on the main thread.
 *
 * The whitelist covers the data-path write commands Dazzle's context
 * manager and the multi-agent bench actually emit: hash mutations (HSET
 * and friends), counters, single-key strings, lists/sets/sorted-sets, and
 * streams.  Multi-key writes (MSET, RENAME, SUNIONSTORE, ...) and writes
 * with replication side effects (MIGRATE, COPY, RESTORE) are intentionally
 * excluded — they fall through to the main-thread path. */
static inline int dazzle_slot_safe_write_cmd(const char *cmd) {
    if (!cmd) return 0;
    static const char *const SAFE_W[] = {
        /* Hash */
        "HSET",   "HMSET",  "HSETNX", "HDEL",
        "HINCRBY","HINCRBYFLOAT",
        /* String / counter */
        "SET",    "SETNX",  "SETEX",  "PSETEX",
        "APPEND", "GETSET", "GETDEL",
        "INCR",   "DECR",   "INCRBY", "DECRBY", "INCRBYFLOAT",
        /* List */
        "LPUSH",  "RPUSH",  "LPUSHX", "RPUSHX",
        "LPOP",   "RPOP",   "LSET",   "LREM",   "LTRIM",  "LINSERT",
        /* Set */
        "SADD",   "SREM",   "SPOP",
        /* Sorted set */
        "ZADD",   "ZREM",   "ZINCRBY",
        "ZPOPMIN","ZPOPMAX",
        /* Stream */
        "XADD",   "XDEL",   "XTRIM",
        /* TTL / keyspace */
        "EXPIRE", "PEXPIRE","EXPIREAT","PEXPIREAT","PERSIST",
        "DEL",    "UNLINK",
        NULL
    };
    for (const char *const *p = SAFE_W; *p; p++) {
        if (strcasecmp(cmd, *p) == 0) return 1;
    }
    return 0;
}

/* Returns 1 if `cmd` is offload-safe at all (read or write).  The
 * dispatcher uses this single predicate to decide whether to hand the
 * request to the worker pool or fall through to the main thread. */
static inline int dazzle_slot_safe_any(const char *cmd) {
    return dazzle_slot_safe_cmd(cmd) || dazzle_slot_safe_write_cmd(cmd);
}

#ifdef __cplusplus
}
#endif

#endif /* VALKEY_IOS || __ANDROID__ */

#endif /* DAZZLE_SLOT_SAFE_H */
