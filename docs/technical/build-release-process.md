# Build & release process

How a commit on `main` ends up in NuGet, npm, pub.dev, Maven Central
and the GitHub Releases tab. Mostly automated, with the manual
gates called out explicitly.

## Branch model

| Branch | Purpose |
|---|---|
| `main` | Stable. Receives PRs only. CI guards (Lint, LLM-attribution check, no-internal-files) gate the merge. |
| `release/X.Y.Z` | Where the next release lives while features and patches accumulate. Becomes `vX.Y.Z` (tag) when ready. |
| `fix/...` / `feat/...` | Short-lived. Open PRs against `release/X.Y.Z` (or against `main` for hotfixes that need to ship immediately). |

The current release line is **`release/1.0.0-beta.5`** → tag
**`v1.0.0-beta.5`**.

## CI workflows that gate every push

`.github/workflows/`:

| File | Trigger | What it does |
|---|---|---|
| `lint.yml` | PR + push | `flutter analyze`, `tsc --noEmit`, `dotnet format` |
| `check-commit-messages.yml` | PR + push | Greps all commits for LLM-attribution patterns. Required. |
| `no-internal-files.yml` | PR + push | Asserts no internal-only paths (e.g. paper drafts, defences config) leaked into the public mirror |
| `security.yml` | PR + push | CodeQL across Kotlin / Swift / Dart / TS |
| `test-c-core.yml` | PR + push touching `core/` | Compiles and runs the C-core unit tests |
| `test-ios.yml` | PR + push touching `sdk/ios/` | XCTest suite via `xcodebuild` |
| `test-android.yml` | PR + push touching `sdk/android/` | Gradle unit tests + lint |
| `dotnet.yml` | PR + push touching `sdk/dotnet/` or `sdk/cpp/` or itself, plus `v*` tags | Native matrix (Linux / macOS / Windows) for libdazzle, .NET 9 build + test against a Valkey 8 service container, **dotnet pack + publish to NuGet.org on tag push** |

All jobs use SHA-pinned actions where possible; `setup-emsdk` is
the one current exception — it pins to `version: latest` and the
release branch tracks Emscripten upstream. Acceptable because
Emscripten doesn't have a history of breaking ABI between minor
versions.

## CI workflows that run on tag push (release.yml)

`release.yml` is the omnibus release workflow, triggered by `v*`
tags:

```
wasm-check          → compile dazzle.wasm fresh, fail if it diverges
                      from the committed copy in sdk/{flutter,react-native}/.../web/native
native-lite × 3 OS  → build libdazzle_lite.{so,dylib,dll}
                      (uploads each as a workflow artefact)
cpp-smoke           → link sdk/cpp-server/test/smoke_test against
                      the Linux artefact, run all 19 round-trip checks
flutter-desktop ×2  → flutter test test/desktop/ on ubuntu + macos,
                      against the per-OS native-lite artefact
release-ios         → xcodebuild → Dazzle.xcframework.zip → GitHub Release asset
release-android     → ./gradlew assembleRelease → dazzle-release.aar → asset
```

The job graph is "fan-in then fan-out": all native builds finish
first, then the cross-platform tests pull artefacts and run.

### permissions block

`release.yml` sets `permissions: contents: write` at the workflow
level so `softprops/action-gh-release` can create the GitHub
Release. Without this the workflow fails 403 inside the job,
which we tripped on the first beta.5 attempt.

## Manual publish steps (intentional)

Some registries don't accept token-based push from GitHub Actions
without setup that we haven't done yet, or have validation steps
that take minutes and would block the workflow. These run from
the maintainer's box:

| Registry | Command | Notes |
|---|---|---|
| pub.dev (`dazzle_flutter`) | `flutter pub publish` | Requires `flutter pub login` once. Interactive confirmation per publish. |
| npm (`dazzle-react-native`, `dazzle-react`) | `npm publish --tag beta` | Requires `npm login` once. The `--tag beta` is critical — without it npm marks the pre-release as `latest`. |
| Maven Central (`com.ivanaliaga:dazzle-sdk`) | `./gradlew publish` from `sdk/android/` | Requires Sonatype credentials in `~/.gradle/gradle.properties`. The vanniktech maven-publish plugin handles the staging dance. |

NuGet (`Dazzle.NET`) is the exception — it's pushed from
`dotnet.yml` directly using a `NUGET_API_KEY` repo secret.

## Per-package release checklist

Before any version bump:

```
# In every distribution package:
sdk/dotnet/                       — README + CHANGELOG entry
sdk/flutter/dazzle_flutter/       — README + CHANGELOG entry
sdk/react-native/dazzle-react-native/  — README + CHANGELOG entry
sdk/react/dazzle-react/           — README + CHANGELOG entry
sdk/ios/                          — README + CHANGELOG entry
sdk/android/                      — README + CHANGELOG entry
sdk/cpp-server/                   — README + CHANGELOG entry

# Plus the cross-stack:
README.md                         — Distribution table
CHANGELOG.md                      — Cross-stack release notes

# Version strings:
sdk/dotnet/Dazzle.NET.csproj                <Version>
sdk/flutter/dazzle_flutter/pubspec.yaml     version:
sdk/react-native/dazzle-react-native/package.json   "version":
sdk/react/dazzle-react/package.json         "version":
sdk/android/build.gradle.kts                val dazzleVersion =
sdk/ios/Package.swift                       (versioned via git tag)
```

A grep for the previous version catches stragglers:

```sh
grep -rn "1\.0\.0-beta\.4" --include="*.md" --include="*.yaml" \
    --include="*.json" --include="*.kts" --include="*.csproj"
```

## Release sequence (mechanical)

```
# 1. Land all the work on release/X.Y.Z
git checkout release/1.0.0-beta.5
# … merge / cherry-pick the PRs that go into this release

# 2. Bump versions everywhere (per-package + cross-stack), commit
$ENVIROMENT_BUMP_SCRIPT_OR_BY_HAND
git commit -am "release: 1.0.0-beta.5 — versions + CHANGELOGs"
git push

# 3. Tag from HEAD of release/X.Y.Z
git tag v1.0.0-beta.5
git push origin v1.0.0-beta.5

# 4. Watch the workflow
gh run watch --exit-status

# 5. Manual registry publishes (see table above)
flutter pub publish                                      # pub.dev
cd sdk/react-native/dazzle-react-native && npm publish --tag beta
cd sdk/react/dazzle-react              && npm publish --tag beta
# Maven Central via Gradle, NuGet via release.yml automatic

# 6. Verify
npm view dazzle-react-native version              # should be 1.0.0-beta.5
flutter pub deps --json | jq -r '.packages[]|.version'
gh release list
```

If a step fails midway: most are idempotent — re-run safely. The
exception is `npm publish` for the same version, which 403s
("cannot publish over existing version"). Bump to `1.0.0-beta.5.1`
or wait for `beta.6`.

## Common gotchas — observed during beta.5

The bugs that bit us in this release, so the next one doesn't
re-trip:

1. **GitHub Actions `local_only` permission** silently breaks every
   workflow that uses `actions/checkout@v4`. Set
   `allowed_actions: all` (or whitelist explicitly) on
   `Settings → Actions → General`.
2. **Branch protection `lock_branch: true`** blocks even `--admin`
   merges. Toggle off when shipping a release branch from a single
   maintainer; restore after.
3. **`actions/upload-artifact@v4` dereferences symlinks** — the
   `libdazzle_lite.so.0` SOVERSION symlink is gone on the consumer
   side. The `cpp-smoke` job recreates it explicitly with `ln -sf`
   before linking.
4. **GNU ld defaults to `--as-needed`**. Source file MUST come
   before `-l` flags or the linker drops the library. Documented
   in `sdk/cpp-server/README.md` so consumers don't trip.
5. **CMake `add_library(SHARED)` with `SOVERSION 0`** produces
   `libfoo.so.0.1.0` + symlinks. Tests that link via the
   unversioned name need the runtime symlink chain present.

## Release notes hygiene

The cross-stack `CHANGELOG.md` documents what changed across the
entire SDK. The per-package CHANGELOGs **scope to that artefact**
— a Flutter Web bug fix doesn't belong in `sdk/cpp-server/CHANGELOG.md`.

When in doubt, ask: "would a developer who only consumes this
package care?" If yes, include in the package CHANGELOG. Otherwise
just the cross-stack one.
