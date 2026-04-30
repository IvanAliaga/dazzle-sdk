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

#include <jni.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <setjmp.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <android/log.h>

#define LOG_TAG "ValkeyMobile"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern int main(int argc, char **argv);

/*
 * Override exit() to prevent Valkey's SHUTDOWN from killing the app process.
 * When Valkey calls exit() on the server thread, we longjmp back instead.
 * Forked children (AOF rewrite) use _exit() normally.
 */
static __thread jmp_buf exit_jmp;
static __thread int exit_jmp_set = 0;
static pid_t server_main_pid = 0;

void exit(int status) {
    /* Let forked children exit normally */
    if (server_main_pid != 0 && getpid() != server_main_pid) {
        _exit(status);
    }
    if (exit_jmp_set) {
        LOGI("exit(%d) intercepted on server thread", status);
        exit_jmp_set = 0;
        longjmp(exit_jmp, status ? status : -1);
    }
    _exit(status);
}

static pthread_t server_thread;
static volatile int server_running = 0;
static int server_port = 0;

/* Cached JNI references — initialised once in JNI_OnLoad, used by every
 * hot-path read. FindClass walks the classloader (10–30 µs on this device
 * at 12 k ops/s = 120–360 ms/s of pure lookup cost) so we keep global
 * refs and avoid the lookup entirely. */
static jclass g_stringCls     = NULL;
static jclass g_stringArrCls  = NULL;

jclass dazzle_jni_string_cls(void) { return g_stringCls; }

/* SIGILL diagnostic handler — installed at JNI_OnLoad so any illegal-
 * instruction trap during the bench surfaces with PC + faulting opcode
 * + nearby instructions in logcat under tag "DazzleSIGILL". This is a
 * pure debugging aid for the Cortex-A73-class chip-compatibility work
 * in §6.3 of the paper; on chips that never fault it is a no-op.
 *
 * After the handler logs the diagnostic, we call dl_iterate_phdr to
 * resolve the library + offset for the faulting PC, then restore the
 * default action so the kernel proceeds with the standard SIGILL
 * delivery (process death + tombstone). The next bench launch can read
 * the logcat trace to identify the exact illegal instruction. */
#include <ucontext.h>
#include <dlfcn.h>

/* MRS-emulation SIGILL handler — userspace shim for CPU feature
 * detection on chips whose kernel does not emulate MRS on the
 * ID_AA64* feature registers. Required for Cortex-A73-class chips
 * running Linux <4.11 (specifically the HiSilicon Kirin 659 +
 * Linux 4.9.148 combination on Huawei P20 Lite EMUI 9 / Android 9).
 *
 * Background. ARMv8-A defines a set of read-only EL1 system
 * registers that report CPU feature bits (ID_AA64ISAR0_EL1,
 * ID_AA64PFR0_EL1, ID_AA64MMFR0_EL1, …). compiler-rt-builtins (NDK
 * 27 prebuilt) and various FetchContent dependencies emit `MRS Xt,
 * ID_AA64*_EL1` instructions in their CPU feature initialisers.
 * Linux 4.11+ traps those MRSes from EL0 and emulates them, so the
 * userspace caller sees a sanitised value. Linux 4.9 does NOT
 * emulate them: the EL1-only MRS faults with SIGILL.
 *
 * Workaround in this handler: detect the MRS pattern, write 0 into
 * the destination register (every feature reported as "absent" — a
 * safe baseline answer), advance PC past the MRS, and resume. The
 * compiler-rt code paths that read these registers fall back to
 * the safe / serial path when feature bits are 0, which is exactly
 * what we want on a chip without those features. */
static void dazzle_sigill_handler(int signo, siginfo_t *info, void *uctx) {
    (void)signo;
    ucontext_t *uc = (ucontext_t *)uctx;
    uintptr_t pc = (uintptr_t)uc->uc_mcontext.pc;
    uint32_t opcode = 0;
    memcpy(&opcode, (const void *)pc, sizeof(opcode));

    /* MRS encoding: 1101_0101_0011_1_o0_op1_CRn_CRm_op2_Rt
     *   bits 31:20 == 0xD53_8 → MRS reading (L=1, the constant 1
     *   bit at [20] for "register transfer" being the MRS direction).
     *   bits 31:21 == 11010101001  (constant)
     *   bit 20      == 1            (MRS direction)
     *   bit 19      == 1            (system register, not implementation
     *                                defined op)
     */
    const uint32_t MRS_MASK   = 0xFFF80000u;
    const uint32_t MRS_PATTERN = 0xD5380000u;  /* MRS Xt, S3_*_*_*_* */
    if ((opcode & MRS_MASK) == MRS_PATTERN) {
        /* Decode + extract Rt and the system register tuple for the log */
        uint32_t op1 = (opcode >> 16) & 7;
        uint32_t CRn = (opcode >> 12) & 0xF;
        uint32_t CRm = (opcode >>  8) & 0xF;
        uint32_t op2 = (opcode >>  5) & 7;
        uint32_t Rt  = opcode & 0x1F;
        LOGI("=== SIGILL: emulating MRS S3_%u_C%u_C%u_%u → x%u (returning 0) ===",
             op1, CRn, CRm, op2, Rt);
        LOGI("  PC=0x%016lx opcode=0x%08x (kernel did not emulate ID_AA64* MRS)",
             (unsigned long)pc, opcode);
        if (Rt != 31) {
            uc->uc_mcontext.regs[Rt] = 0;
        }
        uc->uc_mcontext.pc = pc + 4;  /* skip the faulting instruction */
        return;                        /* resume execution */
    }

    /* Not an MRS we can emulate — fall through to diagnostic dump +
     * default handler so the actual illegal opcode shows up in
     * tombstone / logcat for further debugging. */
    Dl_info dli;
    const char *lib = "?", *sym = "?";
    uintptr_t off = 0;
    if (dladdr((const void *)pc, &dli)) {
        if (dli.dli_fname) lib = dli.dli_fname;
        if (dli.dli_sname) sym = dli.dli_sname;
        off = pc - (uintptr_t)dli.dli_saddr;
    }
    LOGE("=== SIGILL non-MRS, cannot emulate ===");
    LOGE("  signo=%d code=%d", info->si_signo, info->si_code);
    LOGE("  PC=0x%016lx  opcode=0x%08x", (unsigned long)pc, opcode);
    LOGE("  in %s  symbol=%s+0x%lx", lib, sym, (unsigned long)off);
    for (int delta = -4; delta <= 4; ++delta) {
        uint32_t op = 0;
        memcpy(&op, (const void *)(pc + (delta * 4)), sizeof(op));
        LOGE("    [PC%+d*4] = 0x%08x", delta, op);
    }
    LOGE("=== end SIGILL ===");
    struct sigaction sa = { 0 };
    sa.sa_handler = SIG_DFL;
    sigaction(SIGILL, &sa, NULL);
    raise(SIGILL);
}

static void install_sigill_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = dazzle_sigill_handler;
    /* SA_NODEFER keeps the handler installed across re-entry — there
     * are multiple MRS reads in CPU feature detection, all of which
     * must be emulated. SA_SIGINFO gives us the ucontext_t. We do NOT
     * set SA_RESETHAND. */
    sa.sa_flags     = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGILL, &sa, NULL);
    LOGI("SIGILL handler installed (MRS-emulation + diagnostic)");
}

/** Java-callable hook to (re-)install the SIGILL handler. Valkey's
 * setupSignalHandlers() overrides ours during server start, so for
 * the Cortex-A73-class chip-compat debug we need to call this from
 * the bench thread immediately before exercising the Dazzle path. */
JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_VectorBenchmark_nInstallSigillHandler(
    JNIEnv *env, jclass cls)
{
    (void)env; (void)cls;
    install_sigill_handler();
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return -1;

    install_sigill_handler();

    jclass lStr    = (*env)->FindClass(env, "java/lang/String");
    jclass lStrArr = (*env)->FindClass(env, "[Ljava/lang/String;");
    if (!lStr || !lStrArr) return -1;
    g_stringCls    = (jclass)(*env)->NewGlobalRef(env, lStr);
    g_stringArrCls = (jclass)(*env)->NewGlobalRef(env, lStrArr);
    (*env)->DeleteLocalRef(env, lStr);
    (*env)->DeleteLocalRef(env, lStrArr);
    return JNI_VERSION_1_6;
}

typedef struct {
    int argc;
    char **argv;
} server_args_t;

static void *server_thread_func(void *arg) {
    server_args_t *args = (server_args_t *)arg;

    LOGI("Starting Valkey with %d args", args->argc);
    for (int i = 0; i < args->argc; i++) {
        LOGI("  argv[%d] = %s", i, args->argv[i]);
    }

    server_running = 1;
    server_main_pid = getpid();

    int ret;
    int jmp_val = setjmp(exit_jmp);
    if (jmp_val == 0) {
        exit_jmp_set = 1;
        ret = main(args->argc, args->argv);
        exit_jmp_set = 0;
        LOGI("Valkey main() returned %d", ret);
    } else {
        ret = jmp_val;
        LOGI("Valkey exit(%d) caught via longjmp", ret);
    }
    server_running = 0;

    for (int i = 0; i < args->argc; i++) free(args->argv[i]);
    free(args->argv);
    free(args);
    return NULL;
}

/* Graceful shutdown: connect to server and send SHUTDOWN NOSAVE */
static void send_shutdown_command(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        const char *cmd = "*2\r\n$8\r\nSHUTDOWN\r\n$6\r\nNOSAVE\r\n";
        write(sock, cmd, strlen(cmd));
    }
    close(sock);
}

/* ------------------------------------------------------------------
 * nativeStart — receives the full CLI argv array from Kotlin.
 * The Kotlin side translates the typed DazzleConfig into the standard
 * valkey-server argv; this entry point just copies it and spawns the
 * server thread. Parsing persistence / modules / port fallback all
 * happens in Kotlin.
 * ------------------------------------------------------------------ */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeStart(
    JNIEnv *env, jobject thiz, jobjectArray cliArgs) {

    if (server_running) {
        LOGI("Server already running");
        return JNI_TRUE;
    }

    jint n = (*env)->GetArrayLength(env, cliArgs);
    if (n <= 0) {
        LOGE("nativeStart called with empty argv");
        return JNI_FALSE;
    }

    char **argv = calloc((size_t)(n + 1), sizeof(char *));
    if (!argv) return JNI_FALSE;

    int port_from_args = 0;
    for (jint i = 0; i < n; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, cliArgs, i);
        const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
        argv[i] = strdup(utf);
        (*env)->ReleaseStringUTFChars(env, s, utf);
        (*env)->DeleteLocalRef(env, s);

        /* Cheap parse to remember the port we were started with, for the
         * eventual shutdown roundtrip. */
        if (i > 0 && strcmp(argv[i - 1], "--port") == 0) {
            port_from_args = atoi(argv[i]);
        }
    }
    argv[n] = NULL;
    server_port = port_from_args;

    LOGI("Starting Valkey with %d CLI args on port %d", n, port_from_args);

    server_args_t *args = malloc(sizeof(server_args_t));
    args->argc = (int)n;
    args->argv = argv;

    int ret = pthread_create(&server_thread, NULL, server_thread_func, args);
    if (ret != 0) {
        LOGE("Failed to create server thread: %d", ret);
        for (jint i = 0; i < n; i++) free(argv[i]);
        free(argv);
        free(args);
        return JNI_FALSE;
    }
    pthread_detach(server_thread);

    for (int i = 0; i < 50; i++) {
        if (server_running) {
            LOGI("Valkey server thread up on port %d", port_from_args);
            return JNI_TRUE;
        }
        usleep(100000);
    }

    LOGE("Valkey server failed to start within 5 seconds");
    return JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeStop(JNIEnv *env, jobject thiz) {
    if (!server_running) return;

    LOGI("Sending SHUTDOWN command to Valkey");
    send_shutdown_command(server_port);

    for (int i = 0; i < 50; i++) {
        if (!server_running) {
            LOGI("Valkey server stopped gracefully");
            return;
        }
        usleep(100000);
    }
    LOGE("Valkey server did not stop within 5 seconds");
}

JNIEXPORT jboolean JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeIsRunning(JNIEnv *env, jobject thiz) {
    return server_running ? JNI_TRUE : JNI_FALSE;
}

/* Set a process-wide env var from Java.  Needed because Android app processes
 * inherit env from Zygote and `am start --es KEY VAL` does NOT reach getenv.
 * Used by the storage benchmark to flip DAZZLE_PARALLEL_READS before
 * DazzleServer.start() so the worker pool initialises in active mode. */
JNIEXPORT jboolean JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeSetEnv(
    JNIEnv *env, jobject thiz, jstring jkey, jstring jval) {
    if (!jkey || !jval) return JNI_FALSE;
    const char *k = (*env)->GetStringUTFChars(env, jkey, NULL);
    const char *v = (*env)->GetStringUTFChars(env, jval, NULL);
    int rc = setenv(k, v, 1);
    (*env)->ReleaseStringUTFChars(env, jkey, k);
    (*env)->ReleaseStringUTFChars(env, jval, v);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

/* Plan 08: re-read DAZZLE_DISABLE_SNAPSHOT / DAZZLE_SNAPSHOT_BUCKETS into the
 * transport-layer atomics.  dazzle_direct_init() also invokes this on every
 * fresh server start, but that entry point is one-shot per process; sweep
 * harnesses that flip env vars across cells without killing the JVM call
 * this directly after nativeSetEnv so the next ingest/read sees the new
 * configuration without a process restart. */
extern void dazzle_snapshot_reload_config(void);
JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeSnapshotReloadConfig(
    JNIEnv *env, jobject thiz) {
    (void)env; (void)thiz;
    dazzle_snapshot_reload_config();
}

JNIEXPORT jstring JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectCommand(
    JNIEnv *env, jobject thiz, jobjectArray args) {

    jint count = (*env)->GetArrayLength(env, args);
    if (count <= 0) return NULL;

    const char **argv = malloc(count * sizeof(const char *));
    if (!argv) return NULL;

    jstring *jstrings = calloc(count, sizeof(jstring));
    for (jint i = 0; i < count; i++) {
        jstrings[i] = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        argv[i] = (*env)->GetStringUTFChars(env, jstrings[i], NULL);
    }

    extern char *dazzle_direct_command(int argc, const char **argv_strs);
    char *result = dazzle_direct_command((int)count, argv);

    for (jint i = 0; i < count; i++) {
        (*env)->ReleaseStringUTFChars(env, jstrings[i], argv[i]);
    }
    free(jstrings);
    free(argv);

    if (!result) return NULL;
    jstring jresult = (*env)->NewStringUTF(env, result);
    free(result);
    return jresult;
}

/* ------------------------------------------------------------------
 * nativeDirectRead — bypass the event-loop pipe for read commands.
 * Uses a rwlock instead of the pipe+condvar path, eliminating ~800µs
 * of IPC overhead. Returns NULL for unsupported commands, signalling
 * the Kotlin layer to fall back to nativeDirectCommand.
 * ------------------------------------------------------------------ */
JNIEXPORT jstring JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectRead(
    JNIEnv *env, jobject thiz, jobjectArray args) {

    jint count = (*env)->GetArrayLength(env, args);
    if (count <= 0) return NULL;

    const char **argv = malloc(count * sizeof(const char *));
    if (!argv) return NULL;

    jstring *jstrings = calloc(count, sizeof(jstring));
    for (jint i = 0; i < count; i++) {
        jstrings[i] = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        argv[i] = (*env)->GetStringUTFChars(env, jstrings[i], NULL);
    }

    extern char *dazzle_direct_read(int argc, const char **argv_strs);
    char *result = dazzle_direct_read((int)count, argv);

    for (jint i = 0; i < count; i++) {
        (*env)->ReleaseStringUTFChars(env, jstrings[i], argv[i]);
    }
    free(jstrings);
    free(argv);

    if (!result) return NULL;  /* unsupported command → Kotlin falls back to pipe */
    jstring jresult = (*env)->NewStringUTF(env, result);
    free(result);
    return jresult;
}

/* ------------------------------------------------------------------
 * nativeDirectReadFields — Phase 5 partial: typed String[] return.
 *
 * Same as nativeDirectRead(["HMGET", key, f1, f2, ...]) but bypasses
 * RESP serialisation entirely.  The snapshot cache returns field values
 * as a C char*[] which we wrap directly into a Java String[] — no
 * "*N\r\n$len\r\nval\r\n" encoding/decoding round-trip.
 *
 * Savings vs nativeDirectRead (RESP path):
 *   - Eliminates snprintf × N (build RESP)           ~20 µs
 *   - Eliminates Kotlin RESP tokenizer                ~80 µs
 *   - Replaces 1 large NewStringUTF with N small ones (~6 µs vs ~15 µs)
 *   Net saving: ~100 µs → expected total ~50–80 µs per buildContextBlock()
 *
 * Returns null if the key is not in the snapshot (caller falls back to pipe).
 * Individual null elements mean the field does not exist in the cache.
 * ------------------------------------------------------------------ */
#define DAZZLE_STACK_FIELD_CAP 64  /* matches SNAP_MAX_FIELDS in dazzle_transport.c */

JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectReadFields(
    JNIEnv *env, jobject thiz, jstring jkey, jobjectArray jfields) {

    jint nfields = (*env)->GetArrayLength(env, jfields);
    if (nfields <= 0) return NULL;

    const char *key = (*env)->GetStringUTFChars(env, jkey, NULL);

    /* Stack-alloc the field-name resolver arrays for the common case.
     * SNAP_MAX_FIELDS = 64 so anything bigger is by definition a miss on
     * the snapshot side anyway; still handle it via heap for safety. */
    const char *stack_fields[DAZZLE_STACK_FIELD_CAP];
    jstring     stack_jfstrs[DAZZLE_STACK_FIELD_CAP];
    const char **fields;
    jstring     *jfstrs;
    int          heap = nfields > DAZZLE_STACK_FIELD_CAP;
    if (heap) {
        fields = malloc((size_t)nfields * sizeof(const char *));
        jfstrs = calloc((size_t)nfields, sizeof(jstring));
        if (!fields || !jfstrs) {
            free(fields); free(jfstrs);
            (*env)->ReleaseStringUTFChars(env, jkey, key);
            return NULL;
        }
    } else {
        fields = stack_fields;
        jfstrs = stack_jfstrs;
    }

    for (jint i = 0; i < nfields; i++) {
        jfstrs[i] = (jstring)(*env)->GetObjectArrayElement(env, jfields, i);
        fields[i] = (*env)->GetStringUTFChars(env, jfstrs[i], NULL);
    }

    /* Read directly from the snapshot — no RESP, no pipe */
    extern jobjectArray valkey_snapshot_hmget_typed(
        JNIEnv *env, jclass strCls, const char *key,
        int nfields, const char **fields);
    jobjectArray result =
        valkey_snapshot_hmget_typed(env, g_stringCls, key, nfields, fields);

    for (jint i = 0; i < nfields; i++) {
        (*env)->ReleaseStringUTFChars(env, jfstrs[i], fields[i]);
        (*env)->DeleteLocalRef(env, jfstrs[i]);
    }
    (*env)->ReleaseStringUTFChars(env, jkey, key);
    if (heap) { free(fields); free(jfstrs); }

    return result;   /* NULL → caller falls back to nativeDirectRead */
}

/* ------------------------------------------------------------------
 * nativeDirectReadField — single-field fast path.
 *
 * Skips the vararg + Array<String?> dance that nativeDirectReadFields
 * imposes when the caller only wants one field (e.g. Precompute v2's
 * `ctx_block`).  Returns the field value as a jstring directly — no
 * NewObjectArray, no FindClass, no array allocation.
 *
 * Returns null if the key is not cached OR the field is absent.  The
 * caller cannot distinguish a cache miss from an absent field through
 * this path; if it matters, fall back to nativeDirectReadFields.
 * ------------------------------------------------------------------ */
JNIEXPORT jstring JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectReadField(
    JNIEnv *env, jobject thiz, jstring jkey, jstring jfield) {

    if (!jkey || !jfield) return NULL;
    const char *key   = (*env)->GetStringUTFChars(env, jkey, NULL);
    const char *field = (*env)->GetStringUTFChars(env, jfield, NULL);

    char buf[1024];
    extern int valkey_snapshot_hget_typed(const char *key, const char *field,
                                          char *out, int cap);
    int n = valkey_snapshot_hget_typed(key, field, buf, (int)sizeof(buf));

    (*env)->ReleaseStringUTFChars(env, jkey, key);
    (*env)->ReleaseStringUTFChars(env, jfield, field);

    if (n < 0) return NULL;         /* miss — caller falls back */
    return (*env)->NewStringUTF(env, buf);
}

/* ------------------------------------------------------------------
 * nativeDirectHgetall — Phase 7 typed HGETALL that bypasses RESP.
 *
 * Returns a String[] interleaved [k0, v0, k1, v1, …]. Null on
 * snapshot miss so the Kotlin side falls back to the pipe path
 * (HashKey.getAll()).
 *
 * Motivation: ContextStore.get() calls HashKey.getAll() which runs
 * through commandTyped(HGETALL) → Valkey RESP-encodes the multi-bulk
 * → pipe copy → RespParser.parse(). Every step is wasted work when
 * the entry is in the snapshot cache — we already have the (k, v)
 * pairs in memory. This JNI entry point exposes that fact.
 * ------------------------------------------------------------------ */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectHgetall(
    JNIEnv *env, jobject thiz, jstring jkey) {

    if (!jkey) return NULL;
    const char *key = (*env)->GetStringUTFChars(env, jkey, NULL);

    /* Snapshot caps each entry at SNAP_MAX_FIELDS=64 pairs; stack-
     * allocate to match. Anything larger is by construction not in
     * the cache. */
    enum { MAX_PAIRS = 64 };
    char *out_fields[MAX_PAIRS];
    char *out_values[MAX_PAIRS];
    for (int i = 0; i < MAX_PAIRS; i++) { out_fields[i] = NULL; out_values[i] = NULL; }

    extern int dazzle_snapshot_hgetall_typed(const char *key,
                                             char **out_fields,
                                             char **out_values,
                                             int max_pairs);
    int n = dazzle_snapshot_hgetall_typed(key, out_fields, out_values, MAX_PAIRS);

    (*env)->ReleaseStringUTFChars(env, jkey, key);

    if (n < 0) return NULL;   /* miss — Kotlin falls back to HGETALL */

    /* Interleave [k0, v0, k1, v1, …] into a single String[] so the
     * caller only pays one round-trip to enumerate. */
    jobjectArray result = (*env)->NewObjectArray(env, n * 2, g_stringCls, NULL);
    for (int i = 0; i < n; i++) {
        if (out_fields[i]) {
            jstring jk = (*env)->NewStringUTF(env, out_fields[i]);
            (*env)->SetObjectArrayElement(env, result, i * 2, jk);
            (*env)->DeleteLocalRef(env, jk);
            free(out_fields[i]);
        }
        if (out_values[i]) {
            jstring jv = (*env)->NewStringUTF(env, out_values[i]);
            (*env)->SetObjectArrayElement(env, result, i * 2 + 1, jv);
            (*env)->DeleteLocalRef(env, jv);
            free(out_values[i]);
        }
    }
    return result;
}

/* ------------------------------------------------------------------
 * nativeDirectSmembers — Phase 2 typed SMEMBERS. Returns a String[]
 * of members, or null on snapshot miss / wrong type.
 *
 * Same motivation as nativeDirectHgetall: skip the pipe round-trip
 * and the RESP parse. ContextStore.byTag iterates members in a hot
 * loop; every 20 tag-lookups used to cost ~6 ms, now ~0.25 ms.
 * ------------------------------------------------------------------ */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectSmembers(
    JNIEnv *env, jobject thiz, jstring jkey) {

    if (!jkey) return NULL;
    const char *key = (*env)->GetStringUTFChars(env, jkey, NULL);

    enum { MAX_MEMBERS = 64 };
    char *out[MAX_MEMBERS];
    for (int i = 0; i < MAX_MEMBERS; i++) out[i] = NULL;

    extern int dazzle_snapshot_smembers_typed(const char *key,
                                              char **out_members,
                                              int max_members);
    int n = dazzle_snapshot_smembers_typed(key, out, MAX_MEMBERS);
    (*env)->ReleaseStringUTFChars(env, jkey, key);

    if (n < 0) return NULL;

    jobjectArray result = (*env)->NewObjectArray(env, n, g_stringCls, NULL);
    for (int i = 0; i < n; i++) {
        if (out[i]) {
            jstring js = (*env)->NewStringUTF(env, out[i]);
            (*env)->SetObjectArrayElement(env, result, i, js);
            (*env)->DeleteLocalRef(env, js);
            free(out[i]);
        }
    }
    return result;
}

/* ------------------------------------------------------------------
 * nativeDirectZrangeByScore — Phase 2 typed ZRANGEBYSCORE.
 * ------------------------------------------------------------------ */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectZrangeByScore(
    JNIEnv *env, jobject thiz, jstring jkey, jdouble jmin, jdouble jmax) {

    if (!jkey) return NULL;
    const char *key = (*env)->GetStringUTFChars(env, jkey, NULL);

    enum { MAX_MEMBERS = 64 };
    char *out[MAX_MEMBERS];
    for (int i = 0; i < MAX_MEMBERS; i++) out[i] = NULL;

    extern int dazzle_snapshot_zrange_by_score_typed(const char *key,
                                                     double min_score,
                                                     double max_score,
                                                     char **out_members,
                                                     int max_members);
    int n = dazzle_snapshot_zrange_by_score_typed(
        key, (double)jmin, (double)jmax, out, MAX_MEMBERS);
    (*env)->ReleaseStringUTFChars(env, jkey, key);

    if (n < 0) return NULL;

    jobjectArray result = (*env)->NewObjectArray(env, n, g_stringCls, NULL);
    for (int i = 0; i < n; i++) {
        if (out[i]) {
            jstring js = (*env)->NewStringUTF(env, out[i]);
            (*env)->SetObjectArrayElement(env, result, i, js);
            (*env)->DeleteLocalRef(env, js);
            free(out[i]);
        }
    }
    return result;
}

/* ------------------------------------------------------------------
 * nativeDirectGetString — Phase 2 typed GET. Null on miss.
 * ------------------------------------------------------------------ */
JNIEXPORT jstring JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectGetString(
    JNIEnv *env, jobject thiz, jstring jkey) {

    if (!jkey) return NULL;
    const char *key = (*env)->GetStringUTFChars(env, jkey, NULL);

    char buf[4096];
    extern int dazzle_snapshot_get_string_typed(const char *key,
                                                char *out,
                                                int cap);
    int n = dazzle_snapshot_get_string_typed(key, buf, (int)sizeof(buf));

    (*env)->ReleaseStringUTFChars(env, jkey, key);

    if (n < 0) return NULL;
    return (*env)->NewStringUTF(env, buf);
}

/* ------------------------------------------------------------------
 * nativeDirectPipeline — execute N commands in a single batch dispatch.
 *
 * Phase 3 fast path (Android 12+, io_uring available):
 *   - Builds all N DirectRequest structs
 *   - Pushes all to ring buffer (0 syscalls)
 *   - Submits ONE io_uring_enter() with N eventfd-write SQEs (1 syscall)
 *   - Waits on condvar for each result
 *
 * Phase 2 fallback (ring + eventfd):
 *   - Pushes to ring, sends N eventfd writes (N syscalls)
 *
 * Phase 0 fallback (pipe):
 *   - One write()+read() pair per command (2N syscalls)
 *
 * Returns a Java String[] with one element per command. A null
 * element means the command could not be dispatched.
 * ------------------------------------------------------------------ */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeDirectPipeline(
    JNIEnv *env, jobject thiz,
    jobjectArray flatArgs, jintArray lengths) {

    jint numCommands = (*env)->GetArrayLength(env, lengths);
    if (numCommands <= 0)
        return (*env)->NewObjectArray(env, 0, g_stringCls, NULL);

    jint *lenArr = (*env)->GetIntArrayElements(env, lengths, NULL);
    jobjectArray out = (*env)->NewObjectArray(env, numCommands, g_stringCls, NULL);

    /* ── Phase 3 batch path ───────────────────────────────────────────── */
    struct DirectRequest;
    extern struct DirectRequest *dazzle_request_new(int argc, const char **argv_strs);
    extern void  dazzle_request_free(struct DirectRequest *req);
    extern char *dazzle_request_take_result(struct DirectRequest *req);
    extern int   dwp_request_argc(const struct DirectRequest *req);
    extern const char **dwp_request_argv(const struct DirectRequest *req);
    extern void  dazzle_pipeline_dispatch(void **reqs, int n);
    extern void  dazzle_wait_result(void *req);

    struct DirectRequest **reqs = calloc(numCommands, sizeof(struct DirectRequest*));
    jstring **jstrs             = calloc(numCommands, sizeof(jstring*));
    jint      cursor            = 0;

    for (jint cmd = 0; cmd < numCommands; cmd++) {
        jint argc = lenArr[cmd];
        jstrs[cmd] = calloc(argc, sizeof(jstring));

        const char **argv = malloc((size_t)argc * sizeof(const char *));
        for (jint i = 0; i < argc; i++) {
            jstrs[cmd][i] = (jstring)(*env)->GetObjectArrayElement(
                                env, flatArgs, cursor + i);
            argv[i] = (*env)->GetStringUTFChars(env, jstrs[cmd][i], NULL);
        }
        /* Factory owns init of the per-request mutex + cv. */
        reqs[cmd] = dazzle_request_new(argc, argv);
        cursor += argc;
    }

    /* Dispatch all N commands in one batch (Phase 3: 1 syscall if io_uring) */
    dazzle_pipeline_dispatch((void**)reqs, numCommands);

    /* Wait for each result on its own per-request condvar, then collect. */
    for (jint cmd = 0; cmd < numCommands; cmd++) {
        dazzle_wait_result(reqs[cmd]);

        char *result = dazzle_request_take_result(reqs[cmd]);
        if (result) {
            jstring jres = (*env)->NewStringUTF(env, result);
            (*env)->SetObjectArrayElement(env, out, cmd, jres);
            (*env)->DeleteLocalRef(env, jres);
            free(result);
        }

        /* Release string refs */
        int          argc = dwp_request_argc(reqs[cmd]);
        const char **argv = dwp_request_argv(reqs[cmd]);
        for (jint i = 0; i < argc; i++) {
            (*env)->ReleaseStringUTFChars(env, jstrs[cmd][i], argv[i]);
            (*env)->DeleteLocalRef(env, jstrs[cmd][i]);
        }
        free((void*)argv);
        free(jstrs[cmd]);
        dazzle_request_free(reqs[cmd]);
    }

    free(reqs);
    free(jstrs);
    (*env)->ReleaseIntArrayElements(env, lengths, lenArr, JNI_ABORT);
    return out;
}

/* ------------------------------------------------------------------
 * nativeSnapshotMHmget — Phase 6a multi-key typed snapshot HMGET.
 *
 * Amortises the JNI boundary and the snapshot rwlock across N keys:
 * one crossing + one rdlock acquisition answers the whole batch.
 * Falls back transparently at the call site: keys that miss the
 * snapshot come back as null rows, and the caller can reissue them
 * individually through the pipe path.
 *
 * Arguments are passed flat so the JNI layer avoids N*M nested array
 * allocations on the Java side:
 *   keys        String[N]
 *   fieldCounts int[N]; fieldCounts[k] = number of fields for keys[k]
 *   fieldsFlat  String[Σ fieldCounts]; field names in the same order
 *
 * Returns String[N][] where each row is either a String[fieldCounts[k]]
 * (hit; each slot is the value or null if the field is absent) or null
 * (miss — caller falls back to pipe for that key).
 *
 * Returns null if the entire batch missed so the caller can do a cheap
 * null check and go straight to the fallback path.
 * ------------------------------------------------------------------ */
JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_DazzleServer_nativeSnapshotMHmget(
    JNIEnv *env, jobject thiz,
    jobjectArray jkeys, jintArray jfieldCounts, jobjectArray jfieldsFlat) {

    jint nkeys = (*env)->GetArrayLength(env, jkeys);
    if (nkeys <= 0) return NULL;

    jint *counts = (*env)->GetIntArrayElements(env, jfieldCounts, NULL);

    /* Resolve key strings */
    const char **keys   = calloc((size_t)nkeys, sizeof(const char *));
    jstring     *jkstrs = calloc((size_t)nkeys, sizeof(jstring));
    int total = 0;
    for (jint k = 0; k < nkeys; k++) {
        jkstrs[k] = (jstring)(*env)->GetObjectArrayElement(env, jkeys, k);
        keys[k]   = (*env)->GetStringUTFChars(env, jkstrs[k], NULL);
        if (counts[k] > 0) total += counts[k];
    }

    /* Resolve flat field strings */
    size_t slab = total > 0 ? (size_t)total : 1;
    const char **fields = calloc(slab, sizeof(const char *));
    jstring     *jfstrs = calloc(slab, sizeof(jstring));
    for (jint i = 0; i < total; i++) {
        jfstrs[i] = (jstring)(*env)->GetObjectArrayElement(env, jfieldsFlat, i);
        fields[i] = (*env)->GetStringUTFChars(env, jfstrs[i], NULL);
    }

    char **outBuf = calloc(slab, sizeof(char *));

    extern int dazzle_snapshot_mhmget(int nkeys,
                                      const char *const *keys,
                                      const int *field_counts,
                                      const char **fields,
                                      char **out);
    int hit = dazzle_snapshot_mhmget((int)nkeys, keys, counts, fields, outBuf);

    jobjectArray result = NULL;
    if (hit) {
        result = (*env)->NewObjectArray(env, nkeys, g_stringArrCls, NULL);

        int off = 0;
        for (jint k = 0; k < nkeys; k++) {
            jint nf = counts[k];
            if (nf <= 0) {
                jobjectArray row = (*env)->NewObjectArray(env, 0, g_stringCls, NULL);
                (*env)->SetObjectArrayElement(env, result, k, row);
                (*env)->DeleteLocalRef(env, row);
                continue;
            }

            int any = 0;
            for (jint j = 0; j < nf; j++) {
                if (outBuf[off + j]) { any = 1; break; }
            }
            if (any) {
                jobjectArray row = (*env)->NewObjectArray(env, nf, g_stringCls, NULL);
                for (jint j = 0; j < nf; j++) {
                    if (outBuf[off + j]) {
                        jstring s = (*env)->NewStringUTF(env, outBuf[off + j]);
                        (*env)->SetObjectArrayElement(env, row, j, s);
                        (*env)->DeleteLocalRef(env, s);
                    }
                }
                (*env)->SetObjectArrayElement(env, result, k, row);
                (*env)->DeleteLocalRef(env, row);
            }
            /* else: row slot stays null — key missed the snapshot */
            off += nf;
        }
    }

    /* Cleanup */
    for (int i = 0; i < total; i++) {
        free(outBuf[i]);
        (*env)->ReleaseStringUTFChars(env, jfstrs[i], fields[i]);
        (*env)->DeleteLocalRef(env, jfstrs[i]);
    }
    for (jint k = 0; k < nkeys; k++) {
        (*env)->ReleaseStringUTFChars(env, jkstrs[k], keys[k]);
        (*env)->DeleteLocalRef(env, jkstrs[k]);
    }
    free(outBuf);
    free(fields);
    free(jfstrs);
    free(keys);
    free(jkstrs);
    (*env)->ReleaseIntArrayElements(env, jfieldCounts, counts, JNI_ABORT);
    return result;
}
