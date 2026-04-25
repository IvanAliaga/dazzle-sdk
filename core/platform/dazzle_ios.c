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

#include "dazzle_ios.h"
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <setjmp.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <malloc/malloc.h>

/* Defined in zmalloc.c (inside xcframework). All Valkey heap allocations go
   through this zone so zmalloc_get_rss() reports Valkey-only memory, not the
   full-process RSS that would include SwiftUI and other app frameworks. */
extern malloc_zone_t *valkey_ios_zone;

/* Valkey's main() is renamed to valkey_main() during build to avoid
   collision with the app's main() entry point */
extern int valkey_main(int argc, char **argv);

static pthread_t server_thread;
static volatile int server_running = 0;

/* Override exit() to prevent Valkey's SHUTDOWN from killing the app */
static __thread jmp_buf exit_jmp;
static __thread int exit_jmp_set = 0;

void exit(int status) {
    if (exit_jmp_set) {
        exit_jmp_set = 0;
        longjmp(exit_jmp, status ? status : -1);
    }
    _exit(status);
}

typedef struct {
    int argc;
    char **argv;
} server_args_t;

static void *server_thread_func(void *arg) {
    server_args_t *args = (server_args_t *)arg;
    server_running = 1;

    int jmp_val = setjmp(exit_jmp);
    if (jmp_val == 0) {
        exit_jmp_set = 1;
        valkey_main(args->argc, args->argv);
        exit_jmp_set = 0;
    }

    server_running = 0;

    for (int i = 0; i < args->argc; i++) free(args->argv[i]);
    free(args->argv);
    free(args);
    return NULL;
}

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
 * dazzle_ios_start_argv — primary entry point. The Swift side builds
 * the full valkey-server argv from a typed DazzleConfig and passes it
 * here. This function just copies it, spawns the server thread and
 * waits for it to flip server_running.
 * ------------------------------------------------------------------ */
int dazzle_ios_start_argv(int argc, const char **argv_in) {
    if (server_running) return 1;
    if (argc <= 0 || argv_in == NULL) return 0;

    char **argv = calloc((size_t)(argc + 1), sizeof(char *));
    if (!argv) return 0;
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup(argv_in[i]);
    }
    argv[argc] = NULL;

    /* Create the Valkey heap zone before the server thread starts. */
    if (!valkey_ios_zone) {
        valkey_ios_zone = malloc_create_zone(0, 0);
        malloc_set_zone_name(valkey_ios_zone, "ValkeyHeap");
    }

    server_args_t *args = malloc(sizeof(server_args_t));
    args->argc = argc;
    args->argv = argv;

    /* Valkey needs a large stack for deep call chains during startup,
       AOF loading, and Lua script execution. iOS default pthread stack
       is 512KB which causes EXC_BAD_ACCESS (stack overflow). */
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);

    if (pthread_create(&server_thread, &attr, server_thread_func, args) != 0) {
        pthread_attr_destroy(&attr);
        for (int i = 0; i < argc; i++) free(argv[i]);
        free(argv);
        free(args);
        return 0;
    }
    pthread_attr_destroy(&attr);
    pthread_detach(server_thread);

    for (int i = 0; i < 50; i++) {
        if (server_running) return 1;
        usleep(100000);
    }
    return 0;
}

/* ------------------------------------------------------------------
 * dazzle_ios_start — legacy shim. Builds a minimal default argv that
 * matches the pre-DazzleConfig behaviour (AOF on, loopback bind, save
 * disabled) and delegates to dazzle_ios_start_argv().
 * ------------------------------------------------------------------ */
int dazzle_ios_start(const char *data_dir, int port, const char *max_memory) {
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);

    char logpath[512];
    snprintf(logpath, sizeof(logpath), "%s/valkey.log", data_dir);

    const char *argv[] = {
        "valkey-server",
        "--port",            port_str,
        "--bind",            "127.0.0.1",
        "--dir",             data_dir,
        "--maxmemory",       max_memory,
        "--daemonize",       "no",
        "--appendonly",      "yes",
        "--save",            "",
        "--logfile",         logpath,
        "--protected-mode",  "no",
        NULL
    };
    int argc = 0;
    while (argv[argc] != NULL) argc++;

    return dazzle_ios_start_argv(argc, argv);
}

void dazzle_ios_stop(int port) {
    if (!server_running) return;
    send_shutdown_command(port);
    for (int i = 0; i < 50; i++) {
        if (!server_running) return;
        usleep(100000);
    }
}

int dazzle_ios_is_running(void) {
    return server_running;
}

/* Forward declarations for the in-process dispatch engine compiled into the
   xcframework alongside the Valkey source. dazzle_transport.c has access to
   server.h / ae.h; dazzle_ios.c does not, so we use extern declarations. */
extern char *dazzle_direct_command(int argc, const char **argv_strs);
extern char *dazzle_direct_read(int argc, const char **argv_strs);
extern int   dazzle_snapshot_hmget(const char *key, int nfields,
                                   const char **fields, char **out);
extern int   dazzle_snapshot_mhmget(int nkeys,
                                    const char *const *keys,
                                    const int *field_counts,
                                    const char **fields,
                                    char **out);
extern int   dazzle_pipeline_args(int n,
                                  const int *argv_lens,
                                  const char **argv_flat,
                                  char **replies);
extern void  dazzle_direct_free(char *result);
extern void  dazzle_snapshot_reload_config(void);

char *valkey_direct_command(int argc, const char **argv) {
    return dazzle_direct_command(argc, argv);
}

void valkey_direct_free(char *result) {
    dazzle_direct_free(result);
}

/* Phase 1 — answer HMGET from the snapshot cache without touching the pipe.
 * Returns NULL on miss so the caller falls back to valkey_direct_command. */
char *valkey_direct_read(int argc, const char **argv) {
    return dazzle_direct_read(argc, argv);
}

/* Phase 5 — typed HMGET from the snapshot. Skips the RESP envelope. */
int valkey_direct_read_fields(const char *key, int nfields,
                              const char **fields, char **out) {
    return dazzle_snapshot_hmget(key, nfields, fields, out);
}

/* Phase 6a — multi-key snapshot HMGET. Thin pass-through to the transport
 * layer; see dazzle_snapshot_mhmget for the lock/scan contract. */
int valkey_direct_read_mfields(int nkeys,
                               const char *const *keys,
                               const int *field_counts,
                               const char **fields,
                               char **out) {
    return dazzle_snapshot_mhmget(nkeys, keys, field_counts, fields, out);
}

/* Phase 6b — coalesced write pipeline. The FFI side flattens its batch
 * into argv_lens + argv_flat and pays a single crossing here. */
int valkey_pipeline_args(int n,
                         const int *argv_lens,
                         const char **argv_flat,
                         char **replies) {
    return dazzle_pipeline_args(n, argv_lens, argv_flat, replies);
}

/* Plan 08 — re-read the ablation env flags (DAZZLE_DISABLE_SNAPSHOT,
 * DAZZLE_SNAPSHOT_BUCKETS) into transport-layer atomics.  Sweep harnesses
 * that flip env vars mid-run (without killing the host process) should
 * call this after setenv() to guarantee the next operation observes the
 * new configuration.  dazzle_direct_init already calls this on fresh
 * server starts, so single-config callers do NOT need to invoke it. */
void valkey_snapshot_reload_config(void) {
    dazzle_snapshot_reload_config();
}
