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

/* ring_buffer.h — Multi-Producer Single-Consumer ring buffer
 *
 * Phase 2 of the pipe optimization roadmap (see ROADMAP_PIPE_OPTIMIZATION.md).
 * Replaces the OS pipe for dispatching write commands from the app thread to
 * the Valkey event loop, eliminating the write()/read() syscall pair (~100 µs).
 *
 * Design
 * ======
 * SPSC algorithm on the atomic path (producer advances `head`, consumer
 * advances `tail`) with a producer-side mutex that serializes concurrent
 * pushers into a single logical producer.  The suspend SDK (plan 06) lets
 * N Kotlin coroutines call JNI → ring_push from different JVM threads, so
 * the original "producer: exactly one app thread" invariant no longer
 * holds.  The consumer stays lock-free.
 *
 * Rationale: the alternative (lock-free MPSC via CAS loop + deferred
 * publish) requires a second "publish_head" cursor and is easy to get
 * wrong.  A pthread_mutex adds ~100 ns per push, which is negligible vs
 * the ~5 µs eventfd write and ~1 µs call() side-effects on the consumer.
 *
 * Memory ordering:
 *   push: store slot under relaxed, then release-store head.
 *   pop:  acquire-load head to see slot, relaxed-advance tail.
 *
 * Wakeup strategy
 * ===============
 * The ring buffer alone is passive; the event loop sleeps in epoll_wait.
 * We use a Linux eventfd (works on all Android versions) as a wakeup channel:
 *   - App thread: write 1 byte to eventfd (1 syscall, ~5 µs)
 *   - Event loop: registered with aeCreateFileEvent; fires on readable
 *   - Drain: ring_drain_handler() reads all pending requests from the ring
 *
 * This replaces the old approach of writing the pointer itself into the pipe.
 * The savings per command:
 *   Before: write(pipe, &ptr, 8) + read(pipe, &ptr, 8) = ~100 µs combined
 *   After:  write(eventfd, &one, 8) = ~5 µs + atomic load (ring_pop) < 1 µs
 *
 * Usage
 * =====
 *   // App thread (producer):
 *   if (!ring_push(&s_write_ring, req_ptr)) { ... fallback to pipe ... }
 *   ring_notify(&s_ring_eventfd);   // wake event loop (1 syscall)
 *   // then wait on condvar as before for the result
 *
 *   // Event loop thread (consumer), registered via aeCreateFileEvent:
 *   ring_drain_handler(el, fd, priv, mask);   // drains all pending reqs
 *
 * Thread safety
 * =============
 * MPSC — multiple producers, one consumer:
 *   - Producers: any number of app threads; serialized by producer_mtx.
 *   - Consumer: Valkey's event loop thread, lock-free on pop.
 *
 * This header is #included by dazzle_transport.c — no separate .c file needed.
 */

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/eventfd.h>

/* ── Ring buffer constants ──────────────────────────────────────────────── */

#define RING_SIZE     1024   /* must be power of 2; 1024 slots × 8 bytes = 8 KB */
#define RING_MASK     (RING_SIZE - 1)
#define CACHE_LINE    64

/* ── Ring buffer struct ─────────────────────────────────────────────────── */

typedef struct {
    /* Producer cache line */
    _Alignas(CACHE_LINE) _Atomic(uint64_t) head;   /* next slot to write */
    char _pad0[CACHE_LINE - sizeof(_Atomic(uint64_t))];

    /* Consumer cache line */
    _Alignas(CACHE_LINE) _Atomic(uint64_t) tail;   /* next slot to read */
    char _pad1[CACHE_LINE - sizeof(_Atomic(uint64_t))];

    /* Slot array (pointer-sized; each slot holds a DirectRequest*) */
    _Alignas(CACHE_LINE) void *slots[RING_SIZE];
} spsc_ring_t;

/* MPSC producer-side mutex.  Kept outside the ring struct so the hot
 * head/tail cache lines stay exactly the sizes the original SPSC design
 * assumed.  Initialized at program start with PTHREAD_MUTEX_INITIALIZER
 * so there is no init ordering risk vs ring_init. */
static pthread_mutex_t ring_producer_mtx = PTHREAD_MUTEX_INITIALIZER;

/* ── Operations ─────────────────────────────────────────────────────────── */

/* Initialize to empty. Call once before any push/pop. */
static inline void ring_init(spsc_ring_t *r) {
    atomic_store_explicit(&r->head, 0, memory_order_relaxed);
    atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
}

/* Push item from any PRODUCER thread — serialized by ring_producer_mtx.
 * Returns true on success, false if the ring is full (caller must fallback). */
static inline bool ring_push(spsc_ring_t *r, void *item) {
    pthread_mutex_lock(&ring_producer_mtx);
    uint64_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_acquire); /* sync */
    if (h - t >= RING_SIZE) {
        pthread_mutex_unlock(&ring_producer_mtx);
        return false;   /* full */
    }
    r->slots[h & RING_MASK] = item;
    atomic_store_explicit(&r->head, h + 1, memory_order_release); /* publish */
    pthread_mutex_unlock(&ring_producer_mtx);
    return true;
}

/* Pop one item from the CONSUMER thread.
 * Returns the item, or NULL if the ring is empty. */
static inline void *ring_pop(spsc_ring_t *r) {
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t h = atomic_load_explicit(&r->head, memory_order_acquire); /* sync */
    if (t == h) return NULL;   /* empty */
    void *item = r->slots[t & RING_MASK];
    atomic_store_explicit(&r->tail, t + 1, memory_order_release); /* advance */
    return item;
}

/* Number of items currently in the ring (approximate — can change instantly). */
static inline uint64_t ring_size(spsc_ring_t *r) {
    uint64_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    return h - t;
}

/* ── Eventfd wakeup helpers ─────────────────────────────────────────────── */

/* Create the eventfd used to wake the event loop. Returns fd or -1. */
static inline int ring_eventfd_create(void) {
    return eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
}

/* Called by the PRODUCER after ring_push to wake the sleeping event loop.
 * One write() syscall (~5 µs) vs the old pipe write+read pair (~100 µs). */
static inline void ring_notify(int efd) {
    uint64_t one = 1;
    /* Ignore return: EFD_NONBLOCK means it fails if counter would overflow
     * (> UINT64_MAX-1), which is impossible in practice. */
    (void)write(efd, &one, sizeof one);
}

/* Called by the CONSUMER (event loop) handler to drain the wakeup counter
 * so epoll stops reporting the fd as readable. */
static inline void ring_drain_eventfd(int efd) {
    uint64_t val;
    (void)read(efd, &val, sizeof val);   /* nonblocking; ignore errors */
}
