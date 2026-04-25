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
 * dazzle-tfi: Temporal Fault Intelligence module.
 *
 * A Dazzle-specific primitive for LLM-augmented industrial sensor monitoring.
 * Upstream Valkey has no equivalent — this is the module that differentiates
 * Dazzle from the fork.
 *
 * ## Design principles
 *
 *   Offline-first     Every byte lives in-process. No network, no server
 *                     round-trip, no cloud dependency. Runs on-device.
 *   Interpretable     Every decision is traceable through named symbolic
 *                     signals. No black-box weights.
 *   Online-learning   Bayesian posteriors adapt per sensor as confirmed
 *                     faults are observed. No offline training required.
 *   LLM-agnostic      Works identically with Gemma 4, Phi, SmolLM, or any
 *                     future minified model. The LLM stays responsible for
 *                     narrative; TFI handles binary classification.
 *   Status-code aware Consumes NAMUR NE43-style sensor status codes
 *                     (NO_DATA / OUT_OF_RANGE / FAULT / CALIB_ERROR) as
 *                     direct predictive signals.
 *
 * ## Commands
 *
 *   TFI.INIT     <key>
 *       Initialise per-key state. Must be called once before any other TFI
 *       operation on that key.
 *
 *   TFI.INGEST   <key> <minute> <temp> <status>
 *       Notify TFI of a sensor reading. Updates rolling status-code
 *       counters. <status> is one of OK / NO_DATA / OUT_OF_RANGE /
 *       FAULT / CALIB_ERROR.
 *
 *   TFI.EVENT    <key> <minute> <severity>
 *       Append a confirmed fault minute to the event stream. Called when
 *       the LLM detection step confirms a fault.
 *
 *   TFI.SCORE    <key> <atMinute> <winMin> <winMax> <winAvg> <winVel> <precMatchPct>
 *       Compute an assessment. Returns an array:
 *           [probability, predicted, baseRate, clusterDensity,
 *            intervalRatio, precMatchPct, physicalState, signalsCsv]
 *       The binary `predicted` is the OR of the eligible strong signals
 *       that also pass the Bayesian confidence gate — signals whose
 *       posterior has fallen below BAYES_TRIGGER_THRESHOLD after the
 *       warmup phase are treated as uncalibrated and do not fire the
 *       prediction, though they still appear in `signalsCsv`.
 *       Remembers the fired signal set so a subsequent TFI.OBSERVE can
 *       update the Bayesian posteriors.
 *
 *   TFI.OBSERVE  <key> <actualFault>
 *       Update Bayesian posterior (hits/misses) for every signal that was
 *       fired by the most recent TFI.SCORE on this key. <actualFault> is
 *       "1" or "0".
 *
 *   TFI.EXPLAIN  <key>
 *       Return the current Bayesian confidence table — for each signal,
 *       [name, hits, misses, confidence].
 *
 *   TFI.FEATURES <key> <atMinute>
 *       Return the 10-dim feature vector that feeds the scorer. Useful
 *       for paper ablations and external classifiers.
 *
 *   TFI.RESET    <key>
 *       Clear all state for the key (fault history, status counts,
 *       Bayesian posteriors, cached signals).
 *
 * ## Module type
 *
 * TFI state is persisted via a native Valkey module type so it survives
 * RDB/AOF cycles alongside regular keys. Serialisation is explicit — we
 * write a versioned header so future upgrades can evolve the on-disk layout.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <strings.h>

#include "valkeymodule.h"

// ──────────────────────────────────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────────────────────────────────

#define TFI_MODULE_NAME       "dazzle-tfi"
#define TFI_MODULE_VERSION    1
/* Valkey module-type names MUST be exactly 9 ASCII alphanumerics. */
#define TFI_TYPE_NAME         "tfistate1"
#define TFI_TYPE_ENCODING     0

#define TFI_CP_MINUTES        20
#define TFI_CLUSTER_WINDOW    60     /* readings within which to count cluster density */
#define TFI_STATUS_WINDOW     15     /* readings remembered for status-flicker signal.
                                      * Tightened from 25 → 15 to prevent flickers from
                                      * lingering in the buffer for multiple CPs after
                                      * the fault they preceded. 15 still catches
                                      * flickers placed 5-15 readings before a hard
                                      * fault, which is visible at the previous CP's
                                      * prediction query without carrying forward. */
#define TFI_STATUS_MIN_EVENTS 2      /* minimum flickers in the window before
                                      * status_flicker / status_out_of_range fire.
                                      * Isolated (=1) non-OK readings are noise. */

/* Signal identifiers — stable indices used by Bayesian posterior tables. */
enum {
    S_OVERDUE = 0,
    S_INTERVAL_EXPECTED,
    S_CLUSTER_MODERATE,
    S_CLUSTER_DENSE,
    S_PRECURSOR_STRONG,
    S_RISING_NEAR_THRESHOLD,
    S_DROPPING_NEAR_THRESHOLD,
    S_STATUS_FLICKER,
    S_STATUS_OUT_OF_RANGE,
    S_STATUS_FAULT_REPORTED,
    S_COUNT,
};

static const char *SIGNAL_NAMES[S_COUNT] = {
    "overdue",
    "interval_expected",
    "cluster_moderate",
    "cluster_dense",
    "precursor_strong",
    "rising_near_threshold",
    "dropping_near_threshold",
    "status_flicker",
    "status_out_of_range",
    "status_fault_reported",
};

/* NAMUR NE43 status codes. */
enum {
    STATUS_OK = 0,
    STATUS_NO_DATA,
    STATUS_OUT_OF_RANGE,
    STATUS_FAULT,
    STATUS_CALIB_ERROR,
    STATUS_COUNT,
};

static int parse_status(const char *s, size_t len) {
    if (len == 2 && !strncmp(s, "OK", 2))                        return STATUS_OK;
    if (len == 7 && !strncmp(s, "NO_DATA", 7))                   return STATUS_NO_DATA;
    if (len == 12 && !strncmp(s, "OUT_OF_RANGE", 12))            return STATUS_OUT_OF_RANGE;
    if (len == 5 && !strncmp(s, "FAULT", 5))                     return STATUS_FAULT;
    if (len == 11 && !strncmp(s, "CALIB_ERROR", 11))             return STATUS_CALIB_ERROR;
    return STATUS_OK;  /* default — unknown treated as OK */
}

// ──────────────────────────────────────────────────────────────────────────
// State
// ──────────────────────────────────────────────────────────────────────────

typedef struct {
    uint32_t hits;    /* signal fired AND actual fault */
    uint32_t misses;  /* signal fired AND no actual fault */
} BetaStats;

/* Beta prior parameters — prior belief before any observation.
 *
 * Beta(2,3) gives an initial confidence of 0.40 for every signal. This is
 * deliberately optimistic: under-observed signals are given the benefit of
 * the doubt so that the module keeps recall high during the warmup phase of
 * a new monitoring key. As evidence accumulates the posterior converges to
 * the empirical hit rate. */
#define BETA_PRIOR_ALPHA  2.0
#define BETA_PRIOR_BETA   3.0

/* Bayesian gate applied to the binary prediction.
 *
 * A signal only contributes to the OR trigger if its posterior confidence
 * is at least BAYES_TRIGGER_THRESHOLD — otherwise the signal has shown
 * itself to be an unreliable predictor on this key and is suppressed.
 *
 * With Beta(2,3), the confidence trajectory (hits / misses) is:
 *     0/0 → 0.400   (warmup, always allowed)
 *     0/1 → 0.333   (warmup, always allowed)
 *     0/2 → 0.286   < threshold → suppressed
 *     1/2 → 0.429   → re-enabled
 *     0/5 → 0.200   → suppressed
 *     3/0 → 0.833   → strongly allowed
 *
 * During warmup (total observations < BAYES_WARMUP_OBS) the gate is
 * bypassed so that the prediction stays identical to the un-gated OR
 * rule until enough evidence has been collected for the posterior to
 * be informative. */
#define BAYES_TRIGGER_THRESHOLD  0.30
#define BAYES_WARMUP_OBS         2u

static double beta_confidence(const BetaStats *s) {
    double a = (double)s->hits   + BETA_PRIOR_ALPHA;
    double b = (double)s->misses + BETA_PRIOR_BETA;
    return a / (a + b);
}

static int bayes_allow_signal(const BetaStats *s) {
    uint32_t total = s->hits + s->misses;
    if (total < BAYES_WARMUP_OBS) return 1;
    return beta_confidence(s) >= BAYES_TRIGGER_THRESHOLD;
}

typedef struct {
    /* Event stream: sorted ascending, dynamic array */
    int    *fault_minutes;
    size_t  fault_count;
    size_t  fault_cap;

    /* Rolling status-code memory for the last TFI_STATUS_WINDOW readings.
     * We track a small per-reading circular buffer. */
    int     status_ring[TFI_STATUS_WINDOW];
    int     status_ring_minute[TFI_STATUS_WINDOW];
    size_t  status_head;            /* next write position */
    size_t  status_filled;          /* count of valid entries (<=WINDOW) */
    int     last_no_data_minute;    /* -1 if never */
    int     last_out_of_range_minute;
    int     last_fault_reported_minute;

    /* Bayesian posteriors per signal. */
    BetaStats signals[S_COUNT];

    /* Cached signal set from the most recent TFI.SCORE — used by
     * TFI.OBSERVE to update the correct posteriors. */
    uint32_t last_fired_mask;
    int      last_score_minute;
} TfiState;

static TfiState *tfi_state_new(void) {
    TfiState *t = ValkeyModule_Calloc(1, sizeof(*t));
    t->fault_cap   = 16;
    t->fault_minutes = ValkeyModule_Calloc(t->fault_cap, sizeof(int));
    for (int i = 0; i < TFI_STATUS_WINDOW; i++) {
        t->status_ring[i] = STATUS_OK;
        t->status_ring_minute[i] = -1;
    }
    t->last_no_data_minute          = -1;
    t->last_out_of_range_minute     = -1;
    t->last_fault_reported_minute   = -1;
    t->last_score_minute            = -1;
    return t;
}

static void tfi_state_free(TfiState *t) {
    if (!t) return;
    ValkeyModule_Free(t->fault_minutes);
    ValkeyModule_Free(t);
}

static void tfi_state_reset(TfiState *t) {
    t->fault_count = 0;
    for (int i = 0; i < TFI_STATUS_WINDOW; i++) {
        t->status_ring[i] = STATUS_OK;
        t->status_ring_minute[i] = -1;
    }
    t->status_head   = 0;
    t->status_filled = 0;
    t->last_no_data_minute        = -1;
    t->last_out_of_range_minute   = -1;
    t->last_fault_reported_minute = -1;
    for (int i = 0; i < S_COUNT; i++) {
        t->signals[i].hits = 0;
        t->signals[i].misses = 0;
    }
    t->last_fired_mask  = 0;
    t->last_score_minute = -1;
}

static void tfi_state_push_fault(TfiState *t, int minute) {
    if (t->fault_count == t->fault_cap) {
        size_t new_cap = t->fault_cap * 2;
        t->fault_minutes = ValkeyModule_Realloc(t->fault_minutes, new_cap * sizeof(int));
        t->fault_cap = new_cap;
    }
    t->fault_minutes[t->fault_count++] = minute;
}

static void tfi_state_push_status(TfiState *t, int minute, int status) {
    t->status_ring[t->status_head]        = status;
    t->status_ring_minute[t->status_head] = minute;
    t->status_head = (t->status_head + 1) % TFI_STATUS_WINDOW;
    if (t->status_filled < TFI_STATUS_WINDOW) t->status_filled++;

    if (status == STATUS_NO_DATA)            t->last_no_data_minute = minute;
    else if (status == STATUS_OUT_OF_RANGE)  t->last_out_of_range_minute = minute;
    else if (status == STATUS_FAULT ||
             status == STATUS_CALIB_ERROR)   t->last_fault_reported_minute = minute;
}

// ──────────────────────────────────────────────────────────────────────────
// Core scoring — port of FaultRiskEngine (Kotlin) + status-code signals
// ──────────────────────────────────────────────────────────────────────────

typedef struct {
    double probability;
    int    predicted;
    double base_rate;
    int    cluster_density;
    double interval_ratio;
    int    precursor_match_pct;
    const char *physical_state;
    uint32_t signal_mask;
} TfiAssessment;

static const char *physical_state(double win_min, double win_max) {
    if (win_max > 28.0) return "FAULT_HIGH";
    if (win_min <  5.0) return "FAULT_LOW";
    if (win_max > 26.0) return "ELEVATED";
    if (win_min <  8.0) return "COOL";
    return "NORMAL";
}

static TfiAssessment tfi_score(TfiState *t,
                               int      at_minute,
                               double   win_min,
                               double   win_max,
                               double   win_avg,
                               double   win_vel,
                               int      precursor_match_pct) {
    (void)win_avg;   /* reserved for future feature additions */

    TfiAssessment a = {0};
    a.physical_state = physical_state(win_min, win_max);
    a.precursor_match_pct = precursor_match_pct;

    int cps_observed = (at_minute + 1) / TFI_CP_MINUTES;
    a.base_rate = (cps_observed >= 3)
                ? (double)t->fault_count / (double)cps_observed
                : 0.30;

    /* cluster density */
    int recent_faults = 0;
    for (size_t i = 0; i < t->fault_count; i++) {
        if (at_minute - t->fault_minutes[i] <= TFI_CLUSTER_WINDOW)
            recent_faults++;
    }
    a.cluster_density = recent_faults;

    /* interval_ratio */
    double avg_interval = 0.0;
    double time_since_last = (double)INT32_MAX;
    if (t->fault_count >= 2) {
        avg_interval = (double)(t->fault_minutes[t->fault_count - 1] -
                                t->fault_minutes[0])
                     / (double)(t->fault_count - 1);
    }
    if (t->fault_count >= 1) {
        time_since_last = (double)(at_minute - t->fault_minutes[t->fault_count - 1]);
    }
    a.interval_ratio = (avg_interval > 0.0)
                     ? time_since_last / avg_interval
                     : 0.0;

    /* status-code signals from the last TFI_STATUS_WINDOW readings */
    int no_data_count = 0, out_of_range_count = 0, fault_reported = 0;
    for (int i = 0; i < TFI_STATUS_WINDOW; i++) {
        int s = t->status_ring[i];
        int m = t->status_ring_minute[i];
        if (m < 0) continue;
        if (at_minute - m > TFI_STATUS_WINDOW) continue;
        if (s == STATUS_NO_DATA)                                   no_data_count++;
        else if (s == STATUS_OUT_OF_RANGE)                         out_of_range_count++;
        else if (s == STATUS_FAULT || s == STATUS_CALIB_ERROR)     fault_reported++;
    }

    /* Additive probability aggregation with base-rate shrinkage.
     * Same structure as the Kotlin FaultRiskEngine, plus status signals. */
    double prob = a.base_rate * 0.5;
    uint32_t fired = 0;

    /* 1 & 2: interval proximity */
    int interval_expected = (a.interval_ratio >= 0.8 && a.interval_ratio <= 1.4);
    int overdue           = (a.interval_ratio > 1.5);
    if (interval_expected) { fired |= (1u << S_INTERVAL_EXPECTED); prob += 0.22; }
    else if (overdue)      { fired |= (1u << S_OVERDUE);           prob += 0.14; }

    /* 3 & 4: cluster density */
    int cluster_dense    = (recent_faults >= 3);
    int cluster_moderate = (recent_faults == 2);
    if (cluster_dense)            { fired |= (1u << S_CLUSTER_DENSE);    prob += 0.15; }
    else if (cluster_moderate)    { fired |= (1u << S_CLUSTER_MODERATE); prob += 0.08; }
    else if (recent_faults == 1)                                         prob += 0.03;

    /* 5: precursor KNN match */
    int precursor_strong = (precursor_match_pct >= 67);
    if (precursor_strong)             { fired |= (1u << S_PRECURSOR_STRONG); prob += 0.12; }
    else if (precursor_match_pct >= 33)                                      prob += 0.05;

    /* 6: velocity near threshold */
    int rising_near_threshold   = (win_vel >  1.5 && win_max > 25.0);
    int dropping_near_threshold = (win_vel < -1.5 && win_min < 10.0);
    if (rising_near_threshold)   { fired |= (1u << S_RISING_NEAR_THRESHOLD);   prob += 0.10; }
    if (dropping_near_threshold) { fired |= (1u << S_DROPPING_NEAR_THRESHOLD); prob += 0.10; }

    /* Soft current-state contribution (does not by itself trigger). */
    if (win_max > 28.0 || win_min <  5.0) prob += 0.05;
    else if (win_max > 26.0 || win_min < 8.0) prob += 0.03;

    /* 7-9: status-code signals. Real industrial sensors flagging
     * NO_DATA / OUT_OF_RANGE before a hard fault is a concrete engineering
     * observation. We require TFI_STATUS_MIN_EVENTS (2) flickers in the
     * rolling window so a single noisy reading does not trigger; a pattern
     * of degradation does.
     *
     * status_fault_reported fires as a signal (contributes to the
     * probability aggregation and the explanation trace) but intentionally
     * does NOT participate in the binary trigger. Reason: a sensor
     * self-reporting FAULT in the current window tells us the CURRENT
     * window is bad, which is already handled by Task 1 detection. It is
     * not a next-window predictor — in clustered fault processes, the
     * window following a hard fault is more often recovery than
     * continuation. Using it as a trigger inflates FPR without raising
     * recall on the v3 benchmark. */
    int status_flicker        = (no_data_count      >= TFI_STATUS_MIN_EVENTS);
    int status_out_of_range   = (out_of_range_count >= TFI_STATUS_MIN_EVENTS);
    int status_fault_reported = (fault_reported     >= 1);
    if (status_flicker)        { fired |= (1u << S_STATUS_FLICKER);        prob += 0.15; }
    if (status_out_of_range)   { fired |= (1u << S_STATUS_OUT_OF_RANGE);   prob += 0.12; }
    if (status_fault_reported) { fired |= (1u << S_STATUS_FAULT_REPORTED); prob += 0.10; }

    /* Binary prediction: OR of strong signals, gated by Bayesian posterior.
     *
     * Base OR rule membership:
     * - cluster_dense excluded — in sparse fault processes, density ≥3 is
     *   a LATE signal (cluster peak already past).
     * - status_fault_reported excluded — redundant with Task 1 detection
     *   and counter-predictive for next-window cluster continuation.
     *
     * Bayesian gate: each eligible signal only contributes if its posterior
     * confidence (hits vs misses under Beta(2,3)) survives
     * bayes_allow_signal. Signals in warmup (fewer than BAYES_WARMUP_OBS
     * observations) always pass. This turns the engine into an online
     * learner: signals that have repeatedly misfired on this key fall
     * silent, while calibrated signals continue to trigger. */
    #define TRIGGER(fired_flag, idx) \
        ((fired_flag) && bayes_allow_signal(&t->signals[(idx)]))
    a.predicted = TRIGGER(interval_expected,        S_INTERVAL_EXPECTED)
               || TRIGGER(overdue,                  S_OVERDUE)
               || TRIGGER(precursor_strong,         S_PRECURSOR_STRONG)
               || TRIGGER(rising_near_threshold,    S_RISING_NEAR_THRESHOLD)
               || TRIGGER(dropping_near_threshold,  S_DROPPING_NEAR_THRESHOLD)
               || TRIGGER(status_flicker,           S_STATUS_FLICKER)
               || TRIGGER(status_out_of_range,      S_STATUS_OUT_OF_RANGE);
    #undef TRIGGER

    if (prob < 0.0) prob = 0.0;
    if (prob > 1.0) prob = 1.0;
    a.probability = prob;
    a.signal_mask = fired;
    return a;
}

// ──────────────────────────────────────────────────────────────────────────
// Module type (RDB/AOF persistence)
// ──────────────────────────────────────────────────────────────────────────

static ValkeyModuleType *TfiType = NULL;

static void *TfiType_RdbLoad(ValkeyModuleIO *rdb, int encver) {
    (void)encver;
    TfiState *t = tfi_state_new();
    t->fault_count = ValkeyModule_LoadUnsigned(rdb);
    while (t->fault_count > t->fault_cap) {
        t->fault_cap *= 2;
        t->fault_minutes = ValkeyModule_Realloc(t->fault_minutes, t->fault_cap * sizeof(int));
    }
    for (size_t i = 0; i < t->fault_count; i++) {
        t->fault_minutes[i] = (int)ValkeyModule_LoadSigned(rdb);
    }
    for (int i = 0; i < S_COUNT; i++) {
        t->signals[i].hits   = (uint32_t)ValkeyModule_LoadUnsigned(rdb);
        t->signals[i].misses = (uint32_t)ValkeyModule_LoadUnsigned(rdb);
    }
    return t;
}

static void TfiType_RdbSave(ValkeyModuleIO *rdb, void *value) {
    TfiState *t = (TfiState *)value;
    ValkeyModule_SaveUnsigned(rdb, t->fault_count);
    for (size_t i = 0; i < t->fault_count; i++) {
        ValkeyModule_SaveSigned(rdb, t->fault_minutes[i]);
    }
    for (int i = 0; i < S_COUNT; i++) {
        ValkeyModule_SaveUnsigned(rdb, t->signals[i].hits);
        ValkeyModule_SaveUnsigned(rdb, t->signals[i].misses);
    }
}

static void TfiType_Free(void *value) {
    tfi_state_free((TfiState *)value);
}

static size_t TfiType_MemUsage(const void *value) {
    const TfiState *t = (const TfiState *)value;
    return sizeof(*t) + t->fault_cap * sizeof(int);
}

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────

/* Open the key for read+write and fetch-or-create its TfiState.
 * On error, replies to the client and returns NULL. */
static TfiState *open_or_create(ValkeyModuleCtx *ctx, ValkeyModuleString *keyname,
                                int create_if_missing) {
    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname,
        VALKEYMODULE_READ | VALKEYMODULE_WRITE);
    int type = ValkeyModule_KeyType(key);
    if (type == VALKEYMODULE_KEYTYPE_EMPTY) {
        if (!create_if_missing) {
            ValkeyModule_ReplyWithError(ctx, "ERR tfi state not initialised");
            ValkeyModule_CloseKey(key);
            return NULL;
        }
        TfiState *t = tfi_state_new();
        ValkeyModule_ModuleTypeSetValue(key, TfiType, t);
        ValkeyModule_CloseKey(key);
        return t;
    }
    if (ValkeyModule_ModuleTypeGetType(key) != TfiType) {
        ValkeyModule_ReplyWithError(ctx, "WRONGTYPE Key exists but holds a non-TFI value");
        ValkeyModule_CloseKey(key);
        return NULL;
    }
    TfiState *t = ValkeyModule_ModuleTypeGetValue(key);
    ValkeyModule_CloseKey(key);
    return t;
}

static int parse_long(ValkeyModuleCtx *ctx, ValkeyModuleString *s, long long *out) {
    if (ValkeyModule_StringToLongLong(s, out) != VALKEYMODULE_OK) {
        ValkeyModule_ReplyWithError(ctx, "ERR invalid integer");
        return 0;
    }
    return 1;
}

static int parse_double(ValkeyModuleCtx *ctx, ValkeyModuleString *s, double *out) {
    if (ValkeyModule_StringToDouble(s, out) != VALKEYMODULE_OK) {
        ValkeyModule_ReplyWithError(ctx, "ERR invalid double");
        return 0;
    }
    return 1;
}

// ──────────────────────────────────────────────────────────────────────────
// Commands
// ──────────────────────────────────────────────────────────────────────────

/* TFI.INIT <key> */
static int cmd_init(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 2) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;
    ValkeyModule_ReplyWithSimpleString(ctx, "OK");
    return VALKEYMODULE_OK;
}

/* TFI.RESET <key> */
static int cmd_reset(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 2) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;
    tfi_state_reset(t);
    ValkeyModule_ReplyWithSimpleString(ctx, "OK");
    return VALKEYMODULE_OK;
}

/* TFI.INGEST <key> <minute> <temp> <status> */
static int cmd_ingest(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 5) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;

    long long minute;
    if (!parse_long(ctx, argv[2], &minute)) return VALKEYMODULE_OK;

    size_t slen;
    const char *sraw = ValkeyModule_StringPtrLen(argv[4], &slen);
    int status = parse_status(sraw, slen);

    tfi_state_push_status(t, (int)minute, status);
    ValkeyModule_ReplyWithSimpleString(ctx, "OK");
    return VALKEYMODULE_OK;
}

/* TFI.EVENT <key> <minute> <severity> */
static int cmd_event(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 4) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;

    long long minute;
    if (!parse_long(ctx, argv[2], &minute)) return VALKEYMODULE_OK;

    tfi_state_push_fault(t, (int)minute);
    ValkeyModule_ReplyWithSimpleString(ctx, "OK");
    return VALKEYMODULE_OK;
}

/* TFI.SCORE <key> <atMinute> <winMin> <winMax> <winAvg> <winVel> <precMatchPct>
 *
 * Returns: array [probability, predicted, base_rate, cluster_density,
 *                 interval_ratio, precursor_match_pct, physical_state,
 *                 signals_csv]
 */
static int cmd_score(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 8) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;

    long long minute, pmatch;
    double win_min, win_max, win_avg, win_vel;
    if (!parse_long(ctx,   argv[2], &minute))  return VALKEYMODULE_OK;
    if (!parse_double(ctx, argv[3], &win_min)) return VALKEYMODULE_OK;
    if (!parse_double(ctx, argv[4], &win_max)) return VALKEYMODULE_OK;
    if (!parse_double(ctx, argv[5], &win_avg)) return VALKEYMODULE_OK;
    if (!parse_double(ctx, argv[6], &win_vel)) return VALKEYMODULE_OK;
    if (!parse_long(ctx,   argv[7], &pmatch))  return VALKEYMODULE_OK;

    TfiAssessment a = tfi_score(t, (int)minute,
                                win_min, win_max, win_avg, win_vel,
                                (int)pmatch);

    /* Remember fired signals for the next TFI.OBSERVE. */
    t->last_fired_mask   = a.signal_mask;
    t->last_score_minute = (int)minute;

    /* Build a comma-separated signal list. */
    char signals_buf[512];
    size_t off = 0;
    for (int i = 0; i < S_COUNT; i++) {
        if (a.signal_mask & (1u << i)) {
            if (off > 0 && off < sizeof(signals_buf) - 1)
                signals_buf[off++] = ',';
            size_t nlen = strlen(SIGNAL_NAMES[i]);
            if (off + nlen < sizeof(signals_buf) - 1) {
                memcpy(signals_buf + off, SIGNAL_NAMES[i], nlen);
                off += nlen;
            }
        }
    }
    signals_buf[off] = '\0';

    ValkeyModule_ReplyWithArray(ctx, 8);
    ValkeyModule_ReplyWithDouble(ctx, a.probability);
    ValkeyModule_ReplyWithLongLong(ctx, a.predicted ? 1 : 0);
    ValkeyModule_ReplyWithDouble(ctx, a.base_rate);
    ValkeyModule_ReplyWithLongLong(ctx, a.cluster_density);
    ValkeyModule_ReplyWithDouble(ctx, a.interval_ratio);
    ValkeyModule_ReplyWithLongLong(ctx, a.precursor_match_pct);
    ValkeyModule_ReplyWithStringBuffer(ctx, a.physical_state, strlen(a.physical_state));
    ValkeyModule_ReplyWithStringBuffer(ctx, signals_buf, off);
    return VALKEYMODULE_OK;
}

/* TFI.OBSERVE <key> <actualFault> */
static int cmd_observe(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;

    long long actual;
    if (!parse_long(ctx, argv[2], &actual)) return VALKEYMODULE_OK;

    int fault = actual ? 1 : 0;
    for (int i = 0; i < S_COUNT; i++) {
        if (t->last_fired_mask & (1u << i)) {
            if (fault) t->signals[i].hits++;
            else       t->signals[i].misses++;
        }
    }
    /* Once observed, clear the cache so we don't double-count. */
    t->last_fired_mask = 0;

    ValkeyModule_ReplyWithSimpleString(ctx, "OK");
    return VALKEYMODULE_OK;
}

/* TFI.EXPLAIN <key>
 * Returns an array of arrays: [name, hits, misses, confidence] per signal. */
static int cmd_explain(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 2) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 0);
    if (!t) return VALKEYMODULE_OK;

    ValkeyModule_ReplyWithArray(ctx, S_COUNT);
    for (int i = 0; i < S_COUNT; i++) {
        ValkeyModule_ReplyWithArray(ctx, 4);
        ValkeyModule_ReplyWithStringBuffer(ctx, SIGNAL_NAMES[i], strlen(SIGNAL_NAMES[i]));
        ValkeyModule_ReplyWithLongLong(ctx, t->signals[i].hits);
        ValkeyModule_ReplyWithLongLong(ctx, t->signals[i].misses);
        ValkeyModule_ReplyWithDouble(ctx,   beta_confidence(&t->signals[i]));
    }
    return VALKEYMODULE_OK;
}

/* TFI.FEATURES <key> <atMinute>
 * Returns a 10-dim array of raw features — for paper ablations. */
static int cmd_features(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);
    TfiState *t = open_or_create(ctx, argv[1], 1);
    if (!t) return VALKEYMODULE_OK;

    long long minute;
    if (!parse_long(ctx, argv[2], &minute)) return VALKEYMODULE_OK;
    int at = (int)minute;

    int cps_observed = (at + 1) / TFI_CP_MINUTES;
    double base_rate = (cps_observed >= 3)
                     ? (double)t->fault_count / (double)cps_observed
                     : 0.30;

    int recent_faults = 0;
    for (size_t i = 0; i < t->fault_count; i++) {
        if (at - t->fault_minutes[i] <= TFI_CLUSTER_WINDOW) recent_faults++;
    }

    double avg_interval = 0.0;
    double time_since_last = (double)INT32_MAX;
    if (t->fault_count >= 2) {
        avg_interval = (double)(t->fault_minutes[t->fault_count - 1] -
                                t->fault_minutes[0])
                     / (double)(t->fault_count - 1);
    }
    if (t->fault_count >= 1) {
        time_since_last = (double)(at - t->fault_minutes[t->fault_count - 1]);
    }
    double interval_ratio = (avg_interval > 0.0)
                          ? time_since_last / avg_interval
                          : 0.0;

    int no_data = 0, oor = 0, fault_rep = 0;
    for (int i = 0; i < TFI_STATUS_WINDOW; i++) {
        int s = t->status_ring[i];
        int m = t->status_ring_minute[i];
        if (m < 0) continue;
        if (at - m > TFI_STATUS_WINDOW) continue;
        if (s == STATUS_NO_DATA)                               no_data++;
        else if (s == STATUS_OUT_OF_RANGE)                     oor++;
        else if (s == STATUS_FAULT || s == STATUS_CALIB_ERROR) fault_rep++;
    }

    ValkeyModule_ReplyWithArray(ctx, 10);
    ValkeyModule_ReplyWithDouble(ctx, base_rate);
    ValkeyModule_ReplyWithLongLong(ctx, recent_faults);
    ValkeyModule_ReplyWithDouble(ctx, interval_ratio);
    ValkeyModule_ReplyWithLongLong(ctx, (long long)t->fault_count);
    ValkeyModule_ReplyWithDouble(ctx, avg_interval);
    ValkeyModule_ReplyWithDouble(ctx, time_since_last);
    ValkeyModule_ReplyWithLongLong(ctx, no_data);
    ValkeyModule_ReplyWithLongLong(ctx, oor);
    ValkeyModule_ReplyWithLongLong(ctx, fault_rep);
    ValkeyModule_ReplyWithLongLong(ctx, at);
    return VALKEYMODULE_OK;
}

// ──────────────────────────────────────────────────────────────────────────
// Module entry point
// ──────────────────────────────────────────────────────────────────────────
//
// Per-module OnLoad name. Dazzle links every shipped module into libdazzle.so
// (iOS/Android) rather than loading separate .so files at runtime, so each
// module has to export a distinct OnLoad symbol to avoid link-time collision.
// Valkey's patched module loader composes this name from the `@static:<name>`
// sentinel passed to --loadmodule.

__attribute__((visibility("default")))
int ValkeyModule_OnLoad_tfi(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    (void)argv;
    (void)argc;

    if (ValkeyModule_Init(ctx, TFI_MODULE_NAME, TFI_MODULE_VERSION,
                          VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR) {
        return VALKEYMODULE_ERR;
    }

    ValkeyModuleTypeMethods tm = {
        .version     = VALKEYMODULE_TYPE_METHOD_VERSION,
        .rdb_load    = TfiType_RdbLoad,
        .rdb_save    = TfiType_RdbSave,
        .free        = TfiType_Free,
        .mem_usage   = TfiType_MemUsage,
    };
    TfiType = ValkeyModule_CreateDataType(ctx, TFI_TYPE_NAME,
                                          TFI_TYPE_ENCODING, &tm);
    if (TfiType == NULL) return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "tfi.init",     cmd_init,     "write",  1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.reset",    cmd_reset,    "write",  1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.ingest",   cmd_ingest,   "write",  1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.event",    cmd_event,    "write",  1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.score",    cmd_score,    "write",  1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.observe",  cmd_observe,  "write",  1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.explain",  cmd_explain,  "readonly", 1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;
    if (ValkeyModule_CreateCommand(ctx, "tfi.features", cmd_features, "readonly", 1, 1, 1) == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}

// Static-link dead-strip prevention — see the equivalent symbol in
// valkeysearch_module.cc. dazzle_jni.c / dazzle_ios.c takes the address of
// this ref so the linker cannot drop `ValkeyModule_OnLoad_tfi` from the
// final binary even though nothing appears to call it directly.
__attribute__((visibility("default")))
void* const dazzle_tfi_onload_ref = (void*) &ValkeyModule_OnLoad_tfi;
