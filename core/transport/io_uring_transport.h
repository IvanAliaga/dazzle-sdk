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

/* io_uring_transport.h — Phase 3: batch write dispatch via io_uring
 *
 * Phase 3 of the pipe optimization roadmap (ROADMAP_PIPE_OPTIMIZATION.md).
 *
 * Problem
 * =======
 * Phase 2 (ring buffer) pushes N commands to the ring atomically but still
 * calls ring_notify() once per command — N eventfd write() syscalls per
 * pipeline. For a 6-command ingest pipeline: 6 syscalls just for wakeups.
 *
 * Solution
 * ========
 * io_uring batches N eventfd write SQEs into a single io_uring_submit()
 * syscall, reducing N wakeup syscalls to 1 regardless of pipeline size.
 * The event loop wakes once and drains all N requests from the ring buffer.
 *
 *   Before (Phase 2):  ring_push × N + ring_notify × N  = N syscalls
 *   After  (Phase 3):  ring_push × N + uring_submit × 1 = 1 syscall
 *
 * Compatibility
 * =============
 *   Android 12+ (API 31) with kernel 5.10+: io_uring available
 *   Android 11 and below: fallback to Phase 2 (eventfd)
 *
 * Runtime detection via uring_available() — no compile-time guards needed.
 * The pipeline path probes once at first use; result is cached.
 *
 * Architecture
 * ============
 *
 *   App thread (pipeline of N commands):
 *     for each cmd: ring_push(&s_write_ring, req)   // atomic store, 0 syscalls
 *     uring_batch_notify(s_ring_efd, N)              // 1 io_uring_submit() syscall
 *     // wait on condvar for each result (as before)
 *
 *   Event loop thread:
 *     ringDrainHandler fires once (eventfd readable via epoll)
 *     drains all N requests from ring buffer
 *     signals condvar N times
 *
 * Caveat: io_uring is restricted in Android's seccomp-bpf policy on some
 * OEMs. uring_available() handles this: it attempts io_uring_setup(1, ...)
 * and returns false if EPERM or ENOSYS is returned.
 *
 * Usage
 * =====
 *   // In dazzle_transport.c (Android-only, inside #ifdef __ANDROID__):
 *   #include "io_uring_transport.h"
 *
 *   // At init:
 *   s_uring_ok = uring_init(&s_uring);
 *
 *   // In pipeline dispatch (N commands already pushed to ring):
 *   if (s_uring_ok)
 *       uring_batch_notify(&s_uring, s_ring_efd, n_commands);
 *   else
 *       for (int i = 0; i < n_commands; i++) ring_notify(s_ring_efd);
 */

#pragma once

#ifdef __ANDROID__

#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/io_uring.h>

/* ── Minimal io_uring interface (no liburing dependency) ─────────────────── *
 * We use raw syscalls to avoid the liburing dependency.  Only the subset     *
 * needed for our use case (eventfd write SQEs) is implemented here.          *
 * ─────────────────────────────────────────────────────────────────────────── */

/* io_uring syscall numbers (ARM64 Linux) */
#ifndef __NR_io_uring_setup
#define __NR_io_uring_setup    425
#endif
#ifndef __NR_io_uring_enter
#define __NR_io_uring_enter    426
#endif
#ifndef __NR_io_uring_register
#define __NR_io_uring_register 427
#endif

/* Minimal ring context (we only use SQ — no CQ polling needed here) */
#define URING_SQ_SIZE    64   /* must be power of 2; 64 SQEs is plenty */

typedef struct {
    /* Submission queue */
    struct io_uring_sqe *sqes;       /* mmap'd SQE array           */
    uint32_t            *sq_head;    /* kernel advances this        */
    uint32_t            *sq_tail;    /* we advance this             */
    uint32_t            *sq_ring_mask;
    uint32_t            *sq_array;   /* indirection array           */

    /* CQ (we need it for mmap but don't poll it) */
    struct io_uring_cqe *cqes;
    uint32_t            *cq_head;
    uint32_t            *cq_tail;
    uint32_t            *cq_ring_mask;

    /* File descriptors */
    int ring_fd;
    int sq_mmap_size;
    int cq_mmap_size;
    int sqe_mmap_size;

    /* Shared eventfd write value (always 1) */
    uint64_t one;
} uring_ctx_t;

/* ── Probe / init / teardown ──────────────────────────────────────────────── */

/* SIGSYS guard for the io_uring_setup probe.
 *
 * Android's seccomp-bpf policy differs by OEM:
 *   SECCOMP_RET_ERRNO  → syscall returns -1/EPERM  → safe, caught by fd < 0
 *   SECCOMP_RET_TRAP   → kernel sends SIGSYS        → crashes unless caught
 *
 * Motorola devices (confirmed: Moto G35 5G, Android 14) use SECCOMP_RET_TRAP
 * for syscall 425 (io_uring_setup).  We install a temporary handler around
 * the probe so that SIGSYS longjmps back instead of killing the process.
 *
 * _uring_probe_jmp and _uring_sigsys_handler are static (TU-local) — safe
 * because this header is included by exactly one translation unit.
 */
static sigjmp_buf _uring_probe_jmp;
static void _uring_sigsys_handler(int sig) {
    (void)sig;
    siglongjmp(_uring_probe_jmp, 1);
}

/* Returns true if io_uring is usable on this device.
 * Probes with a temporary SIGSYS handler to survive seccomp TRAP policies.
 * Result is cached — safe to call multiple times. */
static inline bool uring_available(void) {
    static int cached = -1;
    if (cached >= 0) return (bool)cached;

    /* Install temporary SIGSYS handler before probing. */
    struct sigaction sa_old, sa_new;
    memset(&sa_new, 0, sizeof sa_new);
    sigemptyset(&sa_new.sa_mask);
    sa_new.sa_handler = _uring_sigsys_handler;
    sigaction(SIGSYS, &sa_new, &sa_old);

    if (sigsetjmp(_uring_probe_jmp, 1) != 0) {
        /* SIGSYS fired — seccomp TRAP blocked io_uring_setup. */
        sigaction(SIGSYS, &sa_old, NULL);
        cached = 0;
        return false;
    }

    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    long fd = syscall(__NR_io_uring_setup, 1u, &p);
    sigaction(SIGSYS, &sa_old, NULL);  /* restore before close() */

    if (fd < 0) {
        cached = 0;
        return false;
    }
    close((int)fd);
    cached = 1;
    return true;
}

/* Initialize io_uring ring.  Returns true on success. */
static inline bool uring_init(uring_ctx_t *ctx) {
    if (!ctx) return false;
    memset(ctx, 0, sizeof *ctx);
    ctx->one = 1;

    struct io_uring_params p;
    memset(&p, 0, sizeof p);

    int fd = (int)syscall(__NR_io_uring_setup, (uint32_t)URING_SQ_SIZE, &p);
    if (fd < 0) return false;
    ctx->ring_fd = fd;

    /* mmap submission queue ring */
    ctx->sq_mmap_size = p.sq_off.array + p.sq_entries * sizeof(uint32_t);
    void *sq_ring = mmap(NULL, ctx->sq_mmap_size,
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_POPULATE, fd,
                         IORING_OFF_SQ_RING);
    if (sq_ring == MAP_FAILED) { close(fd); return false; }

    ctx->sq_head      = (uint32_t*)((char*)sq_ring + p.sq_off.head);
    ctx->sq_tail      = (uint32_t*)((char*)sq_ring + p.sq_off.tail);
    ctx->sq_ring_mask = (uint32_t*)((char*)sq_ring + p.sq_off.ring_mask);
    ctx->sq_array     = (uint32_t*)((char*)sq_ring + p.sq_off.array);

    /* mmap SQE array */
    ctx->sqe_mmap_size = p.sq_entries * sizeof(struct io_uring_sqe);
    ctx->sqes = mmap(NULL, ctx->sqe_mmap_size,
                     PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_POPULATE, fd,
                     IORING_OFF_SQES);
    if (ctx->sqes == MAP_FAILED) {
        munmap(sq_ring, ctx->sq_mmap_size); close(fd); return false;
    }

    /* mmap CQ ring (needed by kernel even if we don't poll it) */
    ctx->cq_mmap_size = p.cq_off.cqes +
                        p.cq_entries * sizeof(struct io_uring_cqe);
    void *cq_ring = mmap(NULL, ctx->cq_mmap_size,
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_POPULATE, fd,
                         IORING_OFF_CQ_RING);
    if (cq_ring == MAP_FAILED) {
        munmap(ctx->sqes, ctx->sqe_mmap_size);
        munmap(sq_ring, ctx->sq_mmap_size);
        close(fd); return false;
    }
    ctx->cq_head      = (uint32_t*)((char*)cq_ring + p.cq_off.head);
    ctx->cq_tail      = (uint32_t*)((char*)cq_ring + p.cq_off.tail);
    ctx->cq_ring_mask = (uint32_t*)((char*)cq_ring + p.cq_off.ring_mask);
    ctx->cqes         = (struct io_uring_cqe*)((char*)cq_ring + p.cq_off.cqes);

    return true;
}

/* ── Batch notify ─────────────────────────────────────────────────────────── *
 * Submit N eventfd write SQEs in a single io_uring_submit (1 syscall).       *
 * Each SQE writes &ctx->one (uint64_t = 1) to efd — identical to             *
 * ring_notify(efd) but batched.                                               *
 *                                                                             *
 * The event loop wakes once and drains all N requests from the ring buffer.   *
 * ─────────────────────────────────────────────────────────────────────────── */
static inline void uring_batch_notify(uring_ctx_t *ctx, int efd, int n) {
    if (n <= 0 || ctx->ring_fd < 0) return;

    /* Clamp to available SQ slots */
    if (n > URING_SQ_SIZE) n = URING_SQ_SIZE;

    uint32_t tail = *ctx->sq_tail;
    uint32_t mask = *ctx->sq_ring_mask;

    /* Prepare N write SQEs, each writing 1 to the eventfd */
    for (int i = 0; i < n; i++) {
        uint32_t idx  = tail & mask;
        struct io_uring_sqe *sqe = &ctx->sqes[idx];
        memset(sqe, 0, sizeof *sqe);

        sqe->opcode   = IORING_OP_WRITE;
        sqe->fd       = efd;
        sqe->addr     = (uint64_t)(uintptr_t)&ctx->one;
        sqe->len      = sizeof(ctx->one);
        sqe->off      = 0;
        sqe->flags    = 0;
        sqe->user_data = (uint64_t)i;

        ctx->sq_array[idx] = idx;  /* identity mapping */
        tail++;
    }

    /* Memory barrier before publishing to kernel */
    __atomic_store_n(ctx->sq_tail, tail, __ATOMIC_RELEASE);

    /* Single syscall: submit all N SQEs */
    syscall(__NR_io_uring_enter, ctx->ring_fd, (uint32_t)n, 0u, 0u, NULL, 0ul);
    /* We fire-and-forget: completions land in CQ but we don't poll them.
     * The eventfd counter accumulates; ringDrainHandler drains it once. */
}

/* Drain completed entries from the CQ ring to prevent overflow.
 * Call periodically (e.g., in ringDrainHandler) if CQ polling is needed. */
static inline void uring_drain_cq(uring_ctx_t *ctx) {
    uint32_t head = *ctx->cq_head;
    uint32_t tail = *ctx->cq_tail;
    uint32_t mask = *ctx->cq_ring_mask;
    while (head != tail) {
        /* struct io_uring_cqe *cqe = &ctx->cqes[head & mask]; */
        (void)mask;   /* suppress unused warning when not inspecting result */
        head++;
    }
    __atomic_store_n(ctx->cq_head, head, __ATOMIC_RELEASE);
}

/* Teardown: unmap and close the ring. */
static inline void uring_destroy(uring_ctx_t *ctx) {
    if (!ctx || ctx->ring_fd < 0) return;
    if (ctx->sqes) munmap(ctx->sqes, ctx->sqe_mmap_size);
    /* CQ and SQ rings share the same mmap on newer kernels; close handles it */
    close(ctx->ring_fd);
    ctx->ring_fd = -1;
}

#endif /* __ANDROID__ */
