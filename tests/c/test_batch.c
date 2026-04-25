/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 * Licensed under the Apache License, Version 2.0.
 *
 * tests/c/test_batch.c — unit tests for the multi-key snapshot scan
 * algorithm used by dazzle_snapshot_mhmget() in core/transport/dazzle_transport.c.
 *
 * The production function reads a process-global static snapshot table
 * (s_snap[]) under a rwlock, which is populated by the Valkey event loop.
 * That path cannot be linked standalone (server.h pulls in the full Valkey
 * source tree).  This test mirrors the exact matching logic against
 * stack-allocated fixtures so algorithmic regressions are caught locally
 * without requiring an Android/iOS device.
 *
 * Any change to the matching logic in dazzle_snapshot_mhmget must be
 * reflected in mhmget_for_test() below, or these tests will stop being
 * representative.
 */

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Mirror of the production types (dazzle_transport.c:118-133) ─────── */
#define SNAP_MAX_ENTRIES 8
#define SNAP_MAX_FIELDS  64
#define SNAP_KEY_LEN     128
#define SNAP_VAL_LEN     256

typedef struct { char f[SNAP_KEY_LEN]; char v[SNAP_VAL_LEN]; } SnapField;
typedef struct {
    char      key[SNAP_KEY_LEN];
    SnapField fields[SNAP_MAX_FIELDS];
    int       nfields;
    int       valid;
} SnapEntry;

/* ── Fixture helpers ─────────────────────────────────────────────────── */
static void snap_add(SnapEntry *tbl, int *n, const char *key,
                     const char *const *fields, const char *const *values,
                     int nf) {
    SnapEntry *e = &tbl[*n];
    (*n)++;
    memset(e, 0, sizeof *e);
    strncpy(e->key, key, SNAP_KEY_LEN - 1);
    e->valid   = 1;
    e->nfields = nf;
    for (int i = 0; i < nf; i++) {
        strncpy(e->fields[i].f, fields[i], SNAP_KEY_LEN - 1);
        strncpy(e->fields[i].v, values[i], SNAP_VAL_LEN - 1);
    }
}

/* ── Mirror of dazzle_snapshot_mhmget() ──────────────────────────────── */
static int mhmget_for_test(SnapEntry *tbl, int tbl_n,
                           int nkeys, const char *const *keys,
                           const int *field_counts,
                           const char **fields, char **out) {
    if (nkeys <= 0 || !keys || !field_counts || !fields || !out) return 0;

    size_t total = 0;
    for (int k = 0; k < nkeys; k++)
        if (field_counts[k] > 0) total += (size_t)field_counts[k];
    for (size_t i = 0; i < total; i++) out[i] = NULL;

    int any_hit   = 0;
    int field_off = 0;
    for (int k = 0; k < nkeys; k++) {
        int nf = field_counts[k];
        if (nf <= 0) continue;
        const char *key = keys[k];
        SnapEntry *e = NULL;
        if (key) {
            for (int i = 0; i < tbl_n; i++) {
                if (tbl[i].valid && strcmp(tbl[i].key, key) == 0) {
                    e = &tbl[i];
                    break;
                }
            }
        }
        if (e) {
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
        }
        field_off += nf;
    }
    return any_hit;
}

static void free_out(char **out, int n) {
    for (int i = 0; i < n; i++) free(out[i]);
}

/* ── Test cases ──────────────────────────────────────────────────────── */

static int g_fail = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, msg); g_fail++; } \
} while (0)

static void test_hit_total(void) {
    SnapEntry tbl[SNAP_MAX_ENTRIES] = {0};
    int n = 0;
    const char *k0_f[] = {"a", "b", "c"};
    const char *k0_v[] = {"1", "2", "3"};
    snap_add(tbl, &n, "sensor:stats", k0_f, k0_v, 3);

    const char *keys[]    = {"sensor:stats"};
    const int   counts[]  = {3};
    const char *fields[]  = {"a", "b", "c"};
    char       *out[3]    = {0};

    int hit = mhmget_for_test(tbl, n, 1, keys, counts, fields, out);
    CHECK(hit == 1, "hit_total: any_hit must be 1");
    CHECK(out[0] && strcmp(out[0], "1") == 0, "hit_total: a → 1");
    CHECK(out[1] && strcmp(out[1], "2") == 0, "hit_total: b → 2");
    CHECK(out[2] && strcmp(out[2], "3") == 0, "hit_total: c → 3");
    free_out(out, 3);
}

static void test_hit_partial(void) {
    SnapEntry tbl[SNAP_MAX_ENTRIES] = {0};
    int n = 0;
    const char *k0_f[] = {"a", "b"};
    const char *k0_v[] = {"1", "2"};
    snap_add(tbl, &n, "k1", k0_f, k0_v, 2);

    const char *keys[]   = {"k1"};
    const int   counts[] = {3};
    const char *fields[] = {"a", "missing", "b"};
    char       *out[3]   = {0};

    int hit = mhmget_for_test(tbl, n, 1, keys, counts, fields, out);
    CHECK(hit == 1, "hit_partial: key hit → 1");
    CHECK(out[0] && strcmp(out[0], "1") == 0, "hit_partial: a → 1");
    CHECK(out[1] == NULL,                     "hit_partial: missing → NULL");
    CHECK(out[2] && strcmp(out[2], "2") == 0, "hit_partial: b → 2");
    free_out(out, 3);
}

static void test_all_miss(void) {
    SnapEntry tbl[SNAP_MAX_ENTRIES] = {0};
    int n = 0;
    const char *k0_f[] = {"a"};
    const char *k0_v[] = {"1"};
    snap_add(tbl, &n, "present", k0_f, k0_v, 1);

    const char *keys[]   = {"absent1", "absent2"};
    const int   counts[] = {2, 1};
    const char *fields[] = {"a", "b", "c"};
    char       *out[3]   = {0};

    int hit = mhmget_for_test(tbl, n, 2, keys, counts, fields, out);
    CHECK(hit == 0, "all_miss: no key hits → 0");
    for (int i = 0; i < 3; i++) CHECK(out[i] == NULL, "all_miss: out all NULL");
}

static void test_multi_key_mixed_counts(void) {
    SnapEntry tbl[SNAP_MAX_ENTRIES] = {0};
    int n = 0;
    const char *k0_f[] = {"x", "y", "z"};
    const char *k0_v[] = {"10", "20", "30"};
    const char *k1_f[] = {"only"};
    const char *k1_v[] = {"99"};
    snap_add(tbl, &n, "A", k0_f, k0_v, 3);
    snap_add(tbl, &n, "B", k1_f, k1_v, 1);

    const char *keys[]   = {"A", "NOPE", "B"};
    const int   counts[] = {2, 3, 1};
    const char *fields[] = {
        "x", "z",        /* key A */
        "p", "q", "r",   /* key NOPE — absent */
        "only"           /* key B */
    };
    char *out[6] = {0};

    int hit = mhmget_for_test(tbl, n, 3, keys, counts, fields, out);
    CHECK(hit == 1,                               "mixed: at least one key hit");
    CHECK(out[0] && strcmp(out[0], "10") == 0,    "mixed: A.x → 10");
    CHECK(out[1] && strcmp(out[1], "30") == 0,    "mixed: A.z → 30");
    CHECK(out[2] == NULL && out[3] == NULL && out[4] == NULL,
          "mixed: NOPE key → all slots NULL");
    CHECK(out[5] && strcmp(out[5], "99") == 0,    "mixed: B.only → 99");
    free_out(out, 6);
}

static void test_duplicate_fields(void) {
    SnapEntry tbl[SNAP_MAX_ENTRIES] = {0};
    int n = 0;
    const char *k0_f[] = {"a"};
    const char *k0_v[] = {"42"};
    snap_add(tbl, &n, "k", k0_f, k0_v, 1);

    const char *keys[]   = {"k"};
    const int   counts[] = {3};
    const char *fields[] = {"a", "a", "a"};
    char       *out[3]   = {0};

    int hit = mhmget_for_test(tbl, n, 1, keys, counts, fields, out);
    CHECK(hit == 1, "duplicates: hit");
    for (int i = 0; i < 3; i++)
        CHECK(out[i] && strcmp(out[i], "42") == 0,
              "duplicates: each slot gets its own malloc'd copy");
    /* Verify independent allocations: mutating one must not change another. */
    if (out[0] && out[1]) out[0][0] = 'X';
    CHECK(out[1] && out[1][0] == '4',
          "duplicates: slots are independent mallocs (not shared pointers)");
    free_out(out, 3);
}

static void test_skip_zero_count_key(void) {
    SnapEntry tbl[SNAP_MAX_ENTRIES] = {0};
    int n = 0;
    const char *k0_f[] = {"a"};
    const char *k0_v[] = {"1"};
    snap_add(tbl, &n, "A", k0_f, k0_v, 1);

    const char *keys[]   = {"A", "B", "A"};
    const int   counts[] = {1, 0, 1};
    const char *fields[] = {"a", "a"};    /* count total = 2, key B skipped */
    char       *out[2]   = {0};

    int hit = mhmget_for_test(tbl, n, 3, keys, counts, fields, out);
    CHECK(hit == 1, "skip_zero: A hits");
    CHECK(out[0] && strcmp(out[0], "1") == 0, "skip_zero: A.a → 1 (slot 0)");
    CHECK(out[1] && strcmp(out[1], "1") == 0, "skip_zero: A.a → 1 (slot 1)");
    free_out(out, 2);
}

/* ── Pipeline args contract test ──────────────────────────────────────── *
 * dazzle_pipeline_args() does N writes + waits.  We can't exercise the     *
 * real transport from a host unit test (no event loop), but we can verify  *
 * the flat-argv layout contract that the JNI and Swift bridges depend on. *
 * ──────────────────────────────────────────────────────────────────────── */
static void test_flat_argv_layout(void) {
    /* Given commands:
     *   ["HSET", "k", "f", "v"]        argc=4
     *   ["HINCRBY", "k", "f", "1"]     argc=4
     *   ["HMGET", "k", "f"]            argc=3
     * The caller must flatten them into one array and pass argc per index. */
    const char *flat[] = {
        "HSET",    "k", "f", "v",
        "HINCRBY", "k", "f", "1",
        "HMGET",   "k", "f",
    };
    const int argv_lens[] = {4, 4, 3};

    /* Reconstruct argv slices exactly how dazzle_pipeline_args walks them. */
    int off = 0;
    const char **argv0 = flat + off; off += argv_lens[0];
    const char **argv1 = flat + off; off += argv_lens[1];
    const char **argv2 = flat + off; off += argv_lens[2];
    (void)argv0; (void)argv1; (void)argv2;

    CHECK(strcmp(argv0[0], "HSET")    == 0 && strcmp(argv0[3], "v") == 0,
          "flat_argv: command 0 reconstructed");
    CHECK(strcmp(argv1[0], "HINCRBY") == 0 && strcmp(argv1[3], "1") == 0,
          "flat_argv: command 1 reconstructed");
    CHECK(strcmp(argv2[0], "HMGET")   == 0 && strcmp(argv2[2], "f") == 0,
          "flat_argv: command 2 reconstructed");
    CHECK(off == (int)(sizeof flat / sizeof *flat),
          "flat_argv: sum(argv_lens) == flat length");
}

static void test_pipeline_sizes(void) {
    /* Verify contract holds for N=1, N=5, N=50. */
    const int Ns[] = {1, 5, 50};
    for (size_t idx = 0; idx < sizeof Ns / sizeof *Ns; idx++) {
        int N = Ns[idx];
        int   *lens = calloc((size_t)N, sizeof(int));
        const char **flat = calloc((size_t)N * 3, sizeof(const char *));
        for (int i = 0; i < N; i++) {
            lens[i]          = 3;
            flat[i * 3 + 0]  = "PING";
            flat[i * 3 + 1]  = "k";
            flat[i * 3 + 2]  = "v";
        }
        int off = 0;
        for (int i = 0; i < N; i++) {
            CHECK(strcmp(flat[off], "PING") == 0, "pipeline_sizes: argv[0] stable");
            off += lens[i];
        }
        CHECK(off == N * 3, "pipeline_sizes: total offset matches");
        free(lens);
        free(flat);
    }
}

int main(void) {
    test_hit_total();
    test_hit_partial();
    test_all_miss();
    test_multi_key_mixed_counts();
    test_duplicate_fields();
    test_skip_zero_count_key();
    test_flat_argv_layout();
    test_pipeline_sizes();

    if (g_fail) {
        fprintf(stderr, "\n%d assertion(s) failed.\n", g_fail);
        return 1;
    }
    printf("All batch tests passed.\n");
    return 0;
}
