# Valkey 9.x — build-time patches

These patches adapt Valkey 9 to the Dazzle embedded model. They
are applied on top of the tree cloned at `git@github.com:valkey-io/valkey.git`
tag `9.0.3`.

## Layout

| File | Applies to | Purpose |
|---|---|---|
| `01_android.patch` | Android | pthread_cancel → pthread_kill(SIGUSR1); glob.h shim (new `src/android_compat.h`); guard `pthread_setcancelstate`; `setproctitle` `__linux__` guard |
| `02_ios.patch` | iOS | stat64 → stat; libproc.h guard; mach_task_self fallback; Lua `system()` stub; `main` → `valkey_main`; custom malloc zone; `zmalloc_get_rss()` zone stats |
| `03_server_hook.patch` | Android + iOS | Injects `dazzle_direct_init()` right after `InitServerLast()` so the embedded transport can register with the server's event loop. Guarded by `#if defined(VALKEY_IOS) \|\| defined(__ANDROID__)` so a single patch serves both platforms. |
| `04_threading.patch` | Android + iOS | Plan 02: moves `server.current_client` / `server.executing_client` to `__thread` storage. 16 files, 84 call sites renamed to `server_current_client` / `server_executing_client` macros that resolve to the TLS slot. Sentinel for idempotency: `dazzle_tls_current_client` in `src/server.h`. Required before flipping `DAZZLE_PARALLEL_READS=1`. |

## How they are applied

- **Android:** `sdk/android/src/main/cpp/apply_patches.sh`, invoked by
  CMake. Applies `01_android.patch` then `03_server_hook.patch`.
- **iOS:** `sdk/ios/build.sh` → `apply_patches()` function, invoked once
  per platform (iphoneos + iphonesimulator). Applies `02_ios.patch`
  then `03_server_hook.patch`.

Both scripts use `git apply --whitespace=nowarn` so the patches must
be in unified diff format. Regenerating them:

```bash
# Start from a pristine clone
git clone --depth 1 --branch 9.0.3 https://github.com/valkey-io/valkey.git /tmp/valkey-fresh
# Make the edits you want, then:
cd /tmp/valkey-fresh && git add -A && git diff --staged > new.patch
```

## Idempotency

Both scripts check for a sentinel line that only exists after patching
(e.g. `pthread_kill(bwd->bio_thread_id` for Android) and exit early if
the tree is already patched. This matters because CMake re-runs
`apply_patches.sh` on every configure.
