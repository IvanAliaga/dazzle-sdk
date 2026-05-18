# Threading & concurrency model

What's safe to call from where, what locks exist, and what
guarantees Dazzle gives across threads — by target.

## Quick reference

| Target | Concurrency model | Hot-path lock |
|---|---|---|
| iOS / Android (full Valkey) | Server thread + bio threads, command serialised on the server thread | `dict.c` global rehash + the snapshot mirror RW-lock |
| Flutter mobile / RN mobile | Same as iOS / Android (binding sits on top) | Same |
| .NET (TCP to sidecar) | Connection-per-call, no shared state in the SDK | (sidecar handles its own locking) |
| Flutter Web / RN Web / React DOM | Single-threaded WASM (browser default) | None — no concurrency |
| Flutter Desktop | Single-threaded `dart:ffi` against `libdazzle_lite` | Caller must serialise |
| C++ server (`libdazzle_lite`) | Single-threaded by construction | Caller must serialise |

## Mobile — full Valkey embedding

When iOS or Android boots Dazzle, the Kotlin / Swift `DazzleServer`
starts a worker thread that runs Valkey's main loop:

```
        ┌── App Main thread / UI thread ──┐
        │                                 │
        │  hash.set("f","v")              │  command queue
        │  hash.getAllDirect()  ─┐        │
        │  vec.search(q, k)      │        │
        └────────────────────────┼────────┘
                                 ▼
                ┌──── Server thread (valkey-main) ────┐
                │  • RESP parser                      │
                │  • command dispatcher               │
                │  • dict.c hashtables, listpacks, …  │
                │  • snapshot-mirror writer           │
                │  • aof / rdb writeout coordinator   │
                └──┬──────────────────────────┬───────┘
                   │                          │
                   ▼                          ▼
         ┌── bio thread pool ──┐    ┌── snapshot mirror ──┐
         │ aof_fsync, lazyfree │    │  read-side caches:  │
         │ aof rewrite child   │    │   field maps,       │
         │                     │    │   sorted-set maps,  │
         └─────────────────────┘    │   stream entries.   │
                                    │  RW-lock per top    │
                                    │  level dict.        │
                                    └─────────────────────┘
```

### Two paths into the data

Writes always go through the **command queue** to the server
thread. The server thread is the only writer; it serialises against
itself. Background I/O (AOF flush, RDB save, lazy free) happens on
the **bio thread pool** — those threads only touch buffers the
server thread already published.

Reads have two paths:

- **RESP path**: `client.dazzleCommand(["HGET", ...])`. Goes through
  the command queue, blocks until the server thread replies.
  ~80–100 µs round-trip on Moto G35 5G because of JNI / FFI cost,
  not the dict lookup itself.
- **Snapshot fast path**: `hash.getAllDirect()`,
  `vec.searchDirect()`, `sset.rangeByScoreDirect()`,
  `set.membersDirect()`, `string.getDirect()`. Skips the command
  queue, reads the snapshot mirror directly via FFI. **~30 µs on
  iPhone 12 Pro A14**. The reader takes a shared lock on the
  per-key dict; the writer thread takes the exclusive lock for the
  duration of one HSET (microseconds).

The snapshot mirror is a write-through cache the server thread
maintains. It's not a copy; it's a pointer to the same `dict.c`
that the server uses. The lock prevents readers from observing a
half-rehashed dict during incremental rehashing.

### Writer-side responsibilities

The server thread holds the exclusive lock only during:

- The actual `dictAdd` / `dictReplace` call
- One step of incremental rehash (~constant time)
- Flushing the listpack buffer for sorted set / hash promotions

Long operations (RDB save, AOF rewrite) happen via fork() on Unix
or via the bio threads, never under the per-dict lock.

### LLM client threading on mobile

The five LLM adapters each have their own threading model on top
of the SDK:

- **`LlamaCppClient`** — owns its own Isolate (Dart) /
  background thread (Swift / Kotlin). Streams tokens via
  `NativeCallable.listener` (Dart) or a dispatch queue (native).
  Zero data copy from llama.cpp to user code.
- **`LiteRtLmClient`** — runs on a Kotlin coroutine (Android) /
  GCD queue (iOS). Bridge invariants in the EventChannel docs.
- **`FoundationModelsClient`** — Apple Intelligence's own
  scheduling. iOS 26+ only.
- **`OpenAICompatibleClient`** — pure Dart / TypeScript HTTP
  client. SSE parser is single-state-machine, no shared state.
- **`AnthropicClient`** — same as OpenAI but messages-API shape.

What's universal across all five: **emit `Delta` on the same thread
the consumer subscribed on**. The native bridges schedule
`onListen` on the platform main thread / Dart UI isolate so app
code never has to thread-hop on every token.

## .NET — TCP-to-sidecar

`Dazzle.NET` doesn't embed Valkey. The `IDazzleClient` opens a TCP
connection per command (no pooling in the current implementation —
a connection pool is on the roadmap). The Valkey/Dazzle server
running as a sidecar handles its own threading.

Concurrency on the .NET side is therefore driven by `async`/`await`
— each request handler can call `IDazzleClient` independently. The
DI singleton is safe to share because each call opens a fresh
socket. **`AUTH` is sent on every connection** (not just the
first), because connections aren't reused yet.

## Web (Flutter Web / RN Web / React DOM)

The browser is single-threaded inside one execution context. `await
DazzleWeb.initialize()` loads the WASM module and runs everything
on the main JS thread. Web Workers and Dart Isolates are the only
ways to get true parallelism, and each one would load its **own**
WASM module instance — no shared state.

Why no SharedArrayBuffer: it requires the host page to send
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` headers. Many static
hosts (GitHub Pages, Netlify free tier) don't set those, and the
performance ceiling is reached by Web Workers anyway for typical
RAG workloads.

If your app does need parallelism — e.g. embedding 10,000 documents
during onboarding — instantiate one `DazzleWeb` per Worker, then
`saveSnapshot()` / `loadSnapshot()` to merge state into the main
thread's instance.

## Desktop / C++ server (`libdazzle_lite`)

The native shared library is **single-threaded by construction**.
The Hash KV (`std::unordered_map`) and the hnswlib instance are
each protected by no internal locks. Concurrent reads from
different threads are undefined; concurrent writes will corrupt
the structure.

Wrap external concurrency at the caller side. Patterns that work:

- **One mutex** around all `dazzle_*` calls. Trivial; fine for
  apps where contention is rare.
- **Reader/writer lock**. Search-heavy workloads benefit because
  hnswlib's search is read-only.
- **Sharded instances**. One `libdazzle_lite` per logical shard
  (per user, per dataset). Each shard's snapshot is independent —
  bring them together by snapshotting separately.

The Flutter Desktop bridge **does not lock automatically**. Apps
that spawn isolates and call `DazzleDesktop` from each one will
race. If your app stays single-isolate (which Flutter Desktop apps
typically do), no caller-side locking is needed.

## Key invariants by stack

| Invariant | iOS/Android | .NET | Web | Desktop |
|---|---|---|---|---|
| Multiple readers simultaneously | ✅ (snapshot RW-lock) | ✅ (separate connections) | ❌ (single-threaded) | ❌ (caller serialises) |
| Multiple writers simultaneously | ❌ (server thread funnels them) | ✅ (sidecar serialises) | ❌ | ❌ |
| Reader-during-writer | ✅ (RW-lock) | ✅ | n/a | ❌ |
| Background snapshot persistence | ✅ (forked child) | (sidecar) | ❌ (host calls explicitly) | ❌ (host calls explicitly) |
| Lock-free hot read path | ✅ (`*Direct()` methods) | ❌ | ✅ | ✅ |
