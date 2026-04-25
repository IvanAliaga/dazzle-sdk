# Dazzle SDK (Android)

Dazzle embeds a patched Valkey server inside your Android app — it runs
in-process, exposes a typed configuration API, and gives the calling app
three command paths with explicit semantics. Think "SQLite, but with
Valkey's data structures (streams, sorted sets, hashes, lists) and
Valkey 9 capabilities plus a pipe-based in-process I/O pipeline."

This README covers v1. For the full feature list across versions see
[ROADMAP.md](../ROADMAP.md). The iOS library mirrors this API; see
`../ios/README.md` for the Swift version.

---

## Quick start

```kotlin
import dev.dazzle.sdk.*

// 1. Start the server with default config (AOF on, port 6379 with
//    fallback, Lua module loaded)
DazzleServer.start(applicationContext)

// 2. Write via the in-process direct path — variadic, values with
//    spaces are safe (no string splitting)
DazzleServer.directCommand("SET", "greeting", "hello world")
DazzleServer.directCommand("XADD", "sensor:readings", "*",
    "temp", "22.3", "humidity", "48")

// 3. Stop when you're done (or let the OS kill the process)
DazzleServer.stop()
```

## Configuration recipes

The shape of `DazzleConfig` is explicit — every knob is a typed field,
nothing is hidden in an assets file. Pass only what you care about and
the rest stays at its default.

| Scenario | Configuration |
|---|---|
| **App cache with recovery** | `DazzleConfig()` — AOF on, loopback TCP on 6379 (with fallback to 6380..6389) |
| **Experiment / benchmark** | `DazzleConfig(port = 6380, persistence = DazzlePersistence.None, wipeOnStart = setOf(WipeTarget.AOF, WipeTarget.RDB))` |
| **In-process only, no TCP** | `DazzleConfig(tcpEnabled = false)` — immune to port conflicts; `directCommand` still works |
| **Custom port, strict** | `DazzleConfig(port = 6500, allowPortFallback = false)` — throws if 6500 is in use |
| **Server for other processes** | `DazzleConfig(bind = "0.0.0.0", protectedMode = true, port = 6379, allowPortFallback = false)` |
| **Paranoid durability** | `DazzleConfig(persistence = DazzlePersistence.Aof(fsync = AppendFsync.ALWAYS))` |
| **Small RAM + fast boot** | `DazzleConfig(persistence = DazzlePersistence.Rdb())` |
| **Debug clean logs** | `DazzleConfig(wipeOnStart = setOf(WipeTarget.LOGS))` |

### Port probing

By default the library tries to bind the preferred `port`, and if it is
in use, falls back to the first free port in `portRange` (defaults to
6379..6389). A warning line goes to the injected `DazzleLogger`. If
every port in the range is in use, `start()` throws
`DazzleException.NoFreePort`. Set `allowPortFallback = false` if you
need the preferred port or nothing.

### Persistence modes

`DazzlePersistence` is a sealed state — you pick exactly one:

- `None` — in-memory only. No AOF, no RDB. Losing the process loses
  the data. Use for tests, experiments and ephemeral caches.
- `Aof(fsync = AppendFsync.EVERYSEC)` — append-only log (default). Up to
  ~1 second of writes lost on crash. The classic "durable cache with
  recovery" mode.
- `Rdb(savePolicy = "...")` — periodic snapshots. Cheaper disk I/O,
  faster boot, loses more data on crash than AOF.

Valkey supports AOF+RDB simultaneously but Dazzle does not expose that
combination — if you really need it, pass both `--appendonly yes` and
`--save "..."` via `DazzleConfig.extraArgs`.

### Cleanup: `WipeTarget`

Granular, composable set of on-disk artifacts the library knows how to
remove:

- `WipeTarget.AOF` — deletes `appendonlydir/`
- `WipeTarget.RDB` — deletes `*.rdb`
- `WipeTarget.LOGS` — deletes `valkey.log`

Apply via `DazzleConfig.wipeOnStart` (runs BEFORE the server boots) or
via `DazzleServer.reset(wipe = ...)` at any time. Shortcuts:
`WipeTarget.NONE` (empty), `WipeTarget.ALL` (everything).

### Modules: `DazzleModule`

First-class enum for the Valkey modules Dazzle can load:

| Module | Shipped today | Throws if requested |
|---|---|---|
| `DazzleModule.Lua` | ✅ | — |
| `DazzleModule.VectorSearch` | ❌ (planned v2) | `ModuleUnavailable` |
| `DazzleModule.TimeSeries` | ❌ (planned v2) | `ModuleUnavailable` |
| `DazzleModule.Json` | ❌ (planned v2) | `ModuleUnavailable` |
| `DazzleModule.Bloom` | ❌ (planned v2) | `ModuleUnavailable` |
| `DazzleModule.Custom(file)` | n/a | depends on file |

Pass the set you want in `DazzleConfig.modules`. Requesting a module
whose `.so` is not packaged produces a loud `DazzleException.ModuleUnavailable`
at `start()` time, never a silent skip.

---

## Command paths

Dazzle exposes **three** ways to send commands to the embedded server.
Use the one that matches your workload.

| Method | Transport | Best for |
|---|---|---|
| `directCommand(vararg args: String)` | in-process pipe | writes, simple reads |
| `directPipeline(commands: List<List<String>>)` | in-process pipe, batched | hot write loops |
| `command(vararg args)` (v1.1+) | persistent TCP loopback | multi-bulk reads (XRANGE, ZRANGE, LRANGE) |

### `directCommand` — variadic, in-process

```kotlin
DazzleServer.directCommand("HSET", "sensor:stats", "count", "42")
DazzleServer.directCommand("XADD", "sensor:readings", "*",
    "temp", "22.3", "humidity", "48")
val count = DazzleServer.directCommand("HGET", "sensor:stats", "count")
```

Values with spaces are safe — there is no string splitting. The returned
string is the parsed RESP reply. For commands that naturally return
arrays (XRANGE, ZRANGE, LRANGE, KEYS, SMEMBERS …) the direct path
flattens the multi-bulk reply into a single concatenated string; if you
need structured access, use the TCP path (coming in v1.1) or the typed
primitives (also v1.1).

### `directPipeline` — batched writes

```kotlin
DazzleServer.directPipeline(listOf(
    listOf("HINCRBYFLOAT", "sensor:stats", "temp_sum", "22.3"),
    listOf("HINCRBY",      "sensor:stats", "count", "1"),
    listOf("ZADD",         "sensor:anomalies", "45", "45"),
))
```

All commands flow through the in-process pipe in one dispatch loop, so
for hot write loops (ingesting 200 readings at once) this cuts per-call
overhead significantly over calling `directCommand` in a tight loop.

### Legacy single-string `directCommand(command: String)`

The old pre-v1 callers that pass `directCommand("HSET key field value")`
still work — the single-string overload is kept with `@Deprecated`. It
splits by whitespace, which silently breaks any value that contains a
space. Migrate to the variadic form.

---

## Lifecycle

```kotlin
// Start (idempotent)
DazzleServer.start(context, DazzleConfig(...))

// Check
DazzleServer.isRunning()   // Boolean
DazzleServer.getPort()     // actual port the server is bound to

// Stop (idempotent)
DazzleServer.stop()

// Nuke artifacts + restart with the same config
DazzleServer.reset(context, wipe = WipeTarget.ALL)
```

Every method is safe to call from any thread. Internally the library
serializes direct commands on Valkey's event loop via a pipe, and the
TCP path is protected by a mutex around a single persistent socket.

**Do NOT call these methods from the Android main thread.** Direct
commands are fast (< 1 ms) but the main thread should stay free of any
blocking I/O. Dispatch them to `Dispatchers.IO` or your own background
thread. Suspend-based wrappers land in v1.1.

---

## Logging and errors

Plug in your own logger via `DazzleConfig.logger`:

```kotlin
object TimberLogger : DazzleLogger {
    override fun debug(tag: String, msg: String) = Timber.tag(tag).d(msg)
    override fun info(tag: String, msg: String)  = Timber.tag(tag).i(msg)
    override fun warn(tag: String, msg: String)  = Timber.tag(tag).w(msg)
    override fun error(tag: String, msg: String, t: Throwable?) =
        Timber.tag(tag).e(t, msg)
}

DazzleServer.start(ctx, DazzleConfig(logger = TimberLogger))
```

The default logger forwards to `android.util.Log` under the tag
`dazzle`. Filter with `adb logcat -s dazzle`.

Errors are always typed — nothing returns silent null for a real
failure. `DazzleException` is a sealed class with variants for start
failures, port conflicts, missing modules, command failures, wrong
types, OOM, and transport errors.

```kotlin
try {
    DazzleServer.start(ctx, DazzleConfig(port = 6500, allowPortFallback = false))
} catch (e: DazzleException.PortInUse) {
    // 6500 is taken, the user already has a Redis running there
} catch (e: DazzleException.ModuleUnavailable) {
    // You requested valkey-search but it's not in this build yet
    Log.w("App", "module '${e.module.label}' not shipped: ${e.message}")
}
```

---

## Threading, concurrency, cancellation

- Every method is thread-safe.
- All methods are currently **synchronous blocking**. Call from
  `Dispatchers.IO` or any non-main-thread pool.
- Suspend-based wrappers (`suspend fun`) are planned for v1.1 as the
  default API; the current sync methods will move behind an opt-in
  `@BlockingApi` annotation.

---

## Native lib packaging — no flags needed

**You do NOT need `android:extractNativeLibs="true"` in your manifest.**
Previous versions of the SDK shipped Valkey's server, the vector-search
module, and the TFI module as three separate `.so` files and loaded the
modules at runtime via `dlopen(<path>)`. That required the modules to be
extracted to the filesystem — which since AGP 3.6 is off by default —
so every consumer had to set the flag.

Starting with the current build, all shipped modules are **statically
linked into a single `libdazzle.so`**. The patched Valkey module loader
resolves `--loadmodule @static:<name>` via `dlopen(RTLD_DEFAULT)` +
`dlsym` against the per-module `ValkeyModule_OnLoad_<name>` symbol,
which is already resident in the process. No filesystem path is needed,
so the consumer's APK packaging flags are irrelevant.

If you're loading an out-of-tree module via `DazzleModule.Custom(File)`,
your app still controls that file and is responsible for keeping it
reachable at the path you supply.
