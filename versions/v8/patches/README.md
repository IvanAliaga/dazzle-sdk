# Valkey 8.x — build-time patches

**Status:** empty. The Dazzle build currently pins to Valkey
9.0.3 (see `sdk/android/src/main/cpp/CMakeLists.txt` `GIT_TAG` and
`sdk/ios/build.sh` `VALKEY_VERSION`). The directory exists so that
when we re-add v8 support, the patch set lives in a predictable place.

When v8 support returns, the expected layout mirrors v9:

```
versions/v8/patches/
├── 01_android.patch      # pthread_cancel → pthread_kill, glob.h shim
├── 02_ios.patch          # stat64, libproc, malloc zone, main rename
└── 03_server_hook.patch  # dazzle_direct_init after InitServerLast
```

Expect some of the upstream files to have moved between v8 and v9 —
`lua/` integration, `hashtable.c`, `vector.c`, etc. — so the patches
will not be byte-identical. Regenerate them from a 8.1.6 clone per the
process documented in `versions/v9/patches/README.md`.
