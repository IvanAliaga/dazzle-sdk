# Security

Threat model and the controls Dazzle ships today, by target.

## Threat model — what's in scope

The SDK's primary deployment story is **on-device** (mobile)
or **in-process** (desktop, embedded C++ servers). The threats we
take seriously:

1. **Process compromise leaks user data.** A vulnerability in the
   host app (the mobile app, the desktop app, the C++ server)
   leads to attacker code running with the same privileges. Goal:
   reduce blast radius.
2. **Network side-channels on .NET.** The .NET binding talks to
   a Valkey/Dazzle server over TCP. An on-path attacker could
   sniff or MITM that traffic.
3. **Persistent state leaks PII across sessions.** Snapshot
   files, AOF, RDB, OPFS blobs sitting on disk in the clear.
4. **Supply chain.** The published artefacts (NuGet, npm,
   pub.dev, Maven) need to be reproducible from the tagged commit
   so consumers can verify what they're running.

## What's in scope explicitly NOT a goal

- **Multi-tenant isolation inside one Dazzle instance.** Hash keys
  with per-tenant prefixes are the user-side pattern; the SDK
  doesn't enforce cross-tenant boundaries within a single embedded
  database. Run separate instances per tenant if you need hard
  isolation.
- **Encryption at rest.** Dazzle does not encrypt the snapshot
  blob, AOF or RDB. Hosts that need at-rest encryption should
  either store on an encrypted FS (iOS Data Protection, macOS
  FileVault, Android EncryptedSharedPreferences-equivalent) or
  encrypt the snapshot bytes before writing.
- **Side-channel resistance for embedding values.** HNSW timing is
  data-dependent — that's how it gets its speed. Apps where embedding
  values themselves are confidential should not co-locate hostile
  query traffic with sensitive corpora.

## Controls today

### Network — .NET TCP transport

`Dazzle.NET` opens a TCP connection per command and supports the
Valkey `AUTH` password challenge. Configuration:

```csharp
builder.Services.AddDazzle(opts =>
{
    opts.Port     = 6379;
    opts.Password = Environment.GetEnvironmentVariable("DAZZLE_PASSWORD");
});
```

- The password is sent unencrypted over the TCP connection unless
  you put a TLS-terminating proxy in front (stunnel, sidecar).
  Future versions will support direct TLS — open issue.
- The password is **never** logged by the SDK. The `IDazzleClient`
  scrubs it from `ToString()` and from any exception messages.
- `AUTH` is sent on every connection (no pool yet).

For production deployments treat the .NET binding as a Redis-style
trusted-network deployment: keep it behind a private subnet,
authenticate, and consider mTLS at the network layer.

### On-device persistence

| Target | Where state lives | Default permissions |
|---|---|---|
| iOS | Keychain (auth state) + app sandbox `Documents/dazzle/` (AOF/RDB) | Sandboxed to the app, encrypted by iOS Data Protection at the file level when the device is locked |
| Android | App-private internal storage (`Context.getFilesDir()`) | Sandboxed to the app's UID, encrypted by File-Based Encryption when the device is locked |
| Flutter Web / RN Web / React DOM | OPFS, scoped to origin | Per-origin, persistent across reloads, isolated by same-origin policy |
| Flutter Desktop | `<cwd>/.dazzle/` by default; `path_provider.getApplicationSupportDirectory()` recommended | Inherits the app data directory's permissions |
| C++ server | Wherever the host writes; not enforced | Host responsibility |

For mobile apps the OS handles the worst cases. On desktop and C++
the host is responsible — the README in each package documents the
recommended location.

### OPFS — same-origin isolation

The web target persists snapshots to the Origin Private File
System. OPFS data is:

- **Origin-scoped.** A different domain or subdomain cannot read
  the snapshot.
- **Persistent across reloads.** Browsers may evict under storage
  pressure (the `navigator.storage.persist()` API exists but is
  user-facing — apps should request persistence explicitly).
- **Not encrypted.** A user with filesystem access to the
  browser's profile dir can read it. Don't store unauthenticated
  PII in web Dazzle.

For multi-user web apps (one origin, multiple logged-in users on
the same browser), pass `opfsFileName: 'user-${userId}.bin'` to
`DazzleWeb.initialize` so a sign-out can `clearAll()` only that
user's blob.

### Supply chain

- **Source-available.** Every line that ends up in any published
  artefact is in `dazzle-sdk` (or vendored under `core/web/build/_deps/`
  via `FetchContent` from a pinned tag).
- **No telemetry.** None of the SDKs phone home. No metrics, no
  crash reports, no analytics endpoints.
- **CI uses pinned actions** where possible. The two unpinned
  exceptions (`mymindstorm/setup-emsdk@v14`,
  `subosito/flutter-action@v2`) track major versions and are
  reviewed before each release line bump.
- **Releases are reproducible from tags** for the lite runtime
  (single TU, no FetchContent at build time once cache is warm).
  The full Valkey embedded build pulls Valkey 9.0.3 +
  valkey-search + hnswlib v0.8.0 via `FetchContent` — those tags
  are immutable on the upstream side.

### LLM-attribution gate

Every PR is scanned for the patterns `co-authored-by`, `claude`,
`anthropic`, `generated with` (case-insensitive) in commit
messages, author/committer fields and trailers. The check is
required for merge. See `.github/workflows/check-commit-messages.yml`.

This isn't a "security" control in the threat-model sense, but it
preserves attribution integrity in the public commit history.

## Reporting a vulnerability

`security@ivanaliaga.com` (PGP key on the GitHub profile) — please
do not open public issues for unpatched security bugs. We aim to
acknowledge within 48 hours and ship a fix within 14 days for
mobile / .NET, longer if the upstream Valkey / llama.cpp is
involved.

## Known unfixed limitations

Tracked under `docs/ROADMAP.md`:

- TLS support in `Dazzle.NET` (today: stunnel / sidecar)
- Encryption-at-rest hooks (today: rely on OS FS encryption)
- Connection pooling in `Dazzle.NET` (today: connection-per-call)

If your deployment can't tolerate any of those, file an issue or
work around at the host layer; the SDK provides composable
primitives, not a packaged production-deployment.
