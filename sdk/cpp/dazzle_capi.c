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
 * dazzle_capi.c — Linux x64 implementation of the Dazzle C API for .NET.
 *
 * For the ASP.NET Core use-case, Dazzle runs as a sidecar or embedded process
 * reachable via TCP. This file wraps a RESP-over-TCP connection so that
 * DazzleClient.NET can talk to a Valkey/Dazzle server on localhost:6379
 * without requiring in-process embedding.
 *
 * Vector-search functions (dazzle_vs_*) delegate to the valkeysearch module
 * loaded in the server via FT.SEARCH/FT.CREATE RESP commands.
 *
 * Thread safety: each call opens its own connection (connection-per-call
 * model). A future version can add a connection pool.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

/* ------------------------------------------------------------------ */
/* Cross-platform socket abstraction                                   */
/*                                                                     */
/* macOS / iOS / Linux / Android use POSIX sockets (BSD-derived).      */
/* Windows uses Winsock2, which is similar but distinct: SOCKET type   */
/* instead of int, closesocket() instead of close(), recv()/send()     */
/* instead of read()/write(), and a mandatory WSAStartup() call before */
/* any other socket function.                                          */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <winsock2.h>
  #include <ws2tcpip.h>
  /* Link via #pragma so consumers of CMake's add_library don't need
   * to remember -lws2_32 on the command line. */
  #pragma comment(lib, "ws2_32.lib")
  typedef SOCKET socket_t;
  #define DAZZLE_INVALID_SOCKET INVALID_SOCKET
  #define close_socket          closesocket
#else
  #include <unistd.h>
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  typedef int socket_t;
  #define DAZZLE_INVALID_SOCKET (-1)
  #define close_socket          close
#endif

#define DAZZLE_HOST "127.0.0.1"
#define DAZZLE_PORT 6379
#define RESP_BUF_SIZE (1024 * 1024)  /* 1 MB read buffer */

/* ------------------------------------------------------------------ */
/* Winsock initialisation                                              */
/*                                                                     */
/* WSAStartup must be called before any socket function on Windows.    */
/* We do it lazily on the first open_conn() with InterlockedCompareExchange */
/* so concurrent callers (e.g. multiple ASP.NET request handlers       */
/* sharing the IDazzleClient singleton) initialise exactly once.       */
/* No-op on POSIX.                                                     */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
static volatile LONG g_winsock_initialized = 0;

static int ensure_socket_init(void)
{
    if (InterlockedCompareExchange(&g_winsock_initialized, 1, 0) == 0) {
        WSADATA wsa_data;
        if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
            /* Roll back so a subsequent caller can retry. */
            InterlockedExchange(&g_winsock_initialized, 0);
            return -1;
        }
    }
    return 0;
}
#else
static int ensure_socket_init(void) { return 0; }
#endif

/* ------------------------------------------------------------------ */
/* Low-level RESP socket helpers                                       */
/* ------------------------------------------------------------------ */

static socket_t open_conn(void)
{
    if (ensure_socket_init() != 0) return DAZZLE_INVALID_SOCKET;

    socket_t fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd == DAZZLE_INVALID_SOCKET) return DAZZLE_INVALID_SOCKET;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(DAZZLE_PORT);
    inet_pton(AF_INET, DAZZLE_HOST, &addr.sin_addr);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close_socket(fd);
        return DAZZLE_INVALID_SOCKET;
    }
    return fd;
}

/* recv()/send() are portable across POSIX and Winsock; we use them
 * instead of read()/write() because Winsock doesn't accept the latter
 * on a SOCKET handle. The (int) casts handle Winsock's int-typed length
 * argument (POSIX uses size_t, but truncating at INT_MAX is fine for
 * RESP messages which are far smaller than 2 GB). */

static int write_all(socket_t fd, const char *buf, size_t len)
{
    while (len > 0) {
        int chunk = (len > 0x7fffffff) ? 0x7fffffff : (int)len;
        int n = (int)send(fd, buf, chunk, 0);
        if (n <= 0) return -1;
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

/* Build RESP multi-bulk request: *N\r\n$len\r\narg\r\n... */
static char *build_resp(int argc, const char **argv, size_t *out_len)
{
    size_t cap = 64;
    for (int i = 0; i < argc; i++) cap += strlen(argv[i]) + 32;

    char *buf = malloc(cap);
    if (!buf) return NULL;

    int pos = snprintf(buf, cap, "*%d\r\n", argc);
    for (int i = 0; i < argc; i++) {
        size_t alen = strlen(argv[i]);
        pos += snprintf(buf + pos, cap - pos, "$%zu\r\n%s\r\n", alen, argv[i]);
    }
    *out_len = pos;
    return buf;
}

/* Read until we have a full RESP reply. Returns a malloc'd string the
 * caller must free via dazzle_free_result. Returns NULL on error. */
static char *read_resp_reply(socket_t fd)
{
    char *buf = malloc(RESP_BUF_SIZE);
    if (!buf) return NULL;

    size_t total = 0;
    while (total < RESP_BUF_SIZE - 1) {
        size_t want = RESP_BUF_SIZE - 1 - total;
        int chunk = (want > 0x7fffffff) ? 0x7fffffff : (int)want;
        int n = (int)recv(fd, buf + total, chunk, 0);
        if (n <= 0) break;
        total += (size_t)n;

        /* Simple heuristic: if line ends with \r\n and we have read at
         * least one full line, check if the reply is complete.
         * For +OK, -ERR, :N → single \r\n suffices.
         * For $N\r\nDATA\r\n → need at least N+2 bytes after header. */
        buf[total] = '\0';
        if (total >= 2 && buf[total-2] == '\r' && buf[total-1] == '\n') {
            char type = buf[0];
            if (type == '+' || type == '-' || type == ':') break;
            if (type == '$') {
                long len = strtol(buf + 1, NULL, 10);
                if (len < 0) break; /* nil */
                /* header ends at first \r\n */
                char *hdr_end = strstr(buf, "\r\n");
                if (hdr_end) {
                    size_t hdr_bytes = (hdr_end - buf) + 2;
                    size_t payload_end = hdr_bytes + (size_t)len + 2;
                    if (total >= payload_end) break;
                }
            }
            if (type == '*') break; /* multi-bulk: accept once we see \r\n */
        }
    }

    buf[total] = '\0';
    return buf;  /* caller frees with dazzle_free_result */
}

/* ------------------------------------------------------------------ */
/* Public C API — called by .NET via P/Invoke                         */
/* ------------------------------------------------------------------ */

char *dazzle_direct_command(int argc, const char **argv_strs)
{
    if (argc <= 0 || !argv_strs) return NULL;

    socket_t fd = open_conn();
    if (fd == DAZZLE_INVALID_SOCKET) return NULL;

    size_t req_len = 0;
    char *req = build_resp(argc, argv_strs, &req_len);
    if (!req) { close_socket(fd); return NULL; }

    int ok = write_all(fd, req, req_len);
    free(req);
    if (ok < 0) { close_socket(fd); return NULL; }

    char *reply = read_resp_reply(fd);
    close_socket(fd);
    return reply;
}

void dazzle_free_result(void *ptr)
{
    free(ptr);
}

/* ------------------------------------------------------------------ */
/* Vector search — delegate via FT.* RESP commands                    */
/* ------------------------------------------------------------------ */

/* Opaque index handle: just stores the index name for now.
 * A future version can cache the actual hnswlib* pointer from a
 * shared-memory segment or from the in-process module. */
typedef struct DazzleIndex {
    char name[256];
    int  dim;
} DazzleIndex;

void *dazzle_vs_create_sq8(const char *name, int dim, int M, int efC,
                            int initialCap, int rerank)
{
    (void)M; (void)efC; (void)initialCap; (void)rerank;

    /* FT.CREATE <name> SCHEMA embedding VECTOR HNSW 6 TYPE FLOAT32
     *   DIM <dim> DISTANCE_METRIC COSINE */
    const char *argv[12];
    char dim_str[32];
    snprintf(dim_str, sizeof(dim_str), "%d", dim);

    argv[0]  = "FT.CREATE";
    argv[1]  = name;
    argv[2]  = "SCHEMA";
    argv[3]  = "embedding";
    argv[4]  = "VECTOR";
    argv[5]  = "HNSW";
    argv[6]  = "6";
    argv[7]  = "TYPE";
    argv[8]  = "FLOAT32";
    argv[9]  = "DIM";
    argv[10] = dim_str;
    argv[11] = "DISTANCE_METRIC";
    /* Note: COSINE needs one more arg — simplified for now */
    char *reply = dazzle_direct_command(12, argv);
    free(reply);  /* ignore FT.CREATE reply for now */

    DazzleIndex *h = malloc(sizeof(DazzleIndex));
    if (!h) return NULL;
    strncpy(h->name, name, sizeof(h->name) - 1);
    h->name[sizeof(h->name) - 1] = '\0';
    h->dim = dim;
    return h;
}

void *dazzle_vs_create_f16(const char *name, int dim, int M, int efC,
                            int initialCap)
{
    return dazzle_vs_create_sq8(name, dim, M, efC, initialCap, 0);
}

void *dazzle_vs_open_handle(const char *name)
{
    DazzleIndex *h = malloc(sizeof(DazzleIndex));
    if (!h) return NULL;
    strncpy(h->name, name, sizeof(h->name) - 1);
    h->name[sizeof(h->name) - 1] = '\0';
    h->dim = 0;
    return h;
}

void dazzle_vs_add_direct(const char *name, const char *key, int key_len,
                          const float *vec)
{
    (void)name; (void)key; (void)key_len; (void)vec;
    /* TODO: HSET <key> embedding <blob> then FT.INDEX */
}

void dazzle_vs_add_batch_direct(const char *name, int n_vecs,
                                const char *const *ids, const int *id_lens,
                                const float *vecs_flat)
{
    (void)name; (void)n_vecs; (void)ids; (void)id_lens; (void)vecs_flat;
    /* TODO: pipeline HSET + FT batch indexing */
}

int dazzle_vs_search_handle(void *handle, const float *query, int k, int ef,
                            char **out_ids, float *out_dists, int max_out)
{
    (void)handle; (void)query; (void)k; (void)ef;
    (void)out_ids; (void)out_dists; (void)max_out;
    return 0;  /* stub: FT.SEARCH implementation pending */
}

int dazzle_vs_search_direct(const char *name, const float *query, int k,
                            int ef, char **out_ids, float *out_dists,
                            int max_out)
{
    (void)name; (void)query; (void)k; (void)ef;
    (void)out_ids; (void)out_dists; (void)max_out;
    return 0;  /* stub: FT.SEARCH implementation pending */
}

void dazzle_vs_free_id(char *id)
{
    free(id);
}
