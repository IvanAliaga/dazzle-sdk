# llama.cpp — pinned version + local patches

Dazzle ships llama.cpp embedded in `libdazzle.so` (Android) and
`Dazzle.xcframework` (iOS), compiled from the tag pinned by the
build scripts. Local workarounds live under `patches/` and are
applied on every clean build.

Mirrors the layout of `versions/v9/patches/` (Valkey).

## Pinned tag

See `LLAMA_VERSION` in:

- `sdk/ios/build.sh`
- `sdk/android/src/main/cpp/CMakeLists.txt`

Both files MUST agree. Bump them together.

## How to add a patch

1. In a fresh clone of llama.cpp at the pinned tag, make the
   changes you need and commit them.
2. `git format-patch -1 HEAD` produces a `.patch` file.
3. Drop it in this directory as `NN_short_name.patch` (NN
   starting at 01, matching the Valkey patch convention).
4. Wire the sentinel into the `apply_patches` stage of each
   build script so a clean re-clone re-applies it.

## Currently applied patches

_(none yet — placeholder for future workarounds like the
multimodal / audio branch fixes)_
