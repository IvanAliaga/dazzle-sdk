# .NET quickstart

P/Invoke bindings to the Dazzle native library, packaged as a NuGet
distributable. Targets **net9.0** and ships pre-built native binaries
for `linux-x64`, `linux-arm64`, `osx-arm64` and `win-x64` under
`runtimes/{rid}/native/`. The right binary is copied next to your
output automatically by the bundled MSBuild targets — no host C++
toolchain required on consumer machines.

Latest: **v1.0.0-beta.5**.

## Install

```bash
dotnet add package Dazzle.NET --version 1.0.0-beta.5
```

## Hello world

```csharp
using Dazzle;
using Dazzle.Hosting;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDazzle(opts =>
{
    opts.Port     = 6379;
    opts.Password = Environment.GetEnvironmentVariable("DAZZLE_PASSWORD");
    opts.DefaultVectorDimension = 1536;
});

var app = builder.Build();

app.MapPost("/search", async (IDazzleClient dazzle, SearchRequest req) =>
{
    var hits = await dazzle.SearchVectorAsync("catalog", req.Query, k: 5);
    return Results.Ok(hits);
});

app.Run();

record SearchRequest(float[] Query);
```

## Configuration

| Option                   | Default | Description                                   |
|--------------------------|---------|-----------------------------------------------|
| `Port`                   | `6379`  | Dazzle / Valkey server port                   |
| `Password`               | `null`  | AUTH password — source from a secrets manager |
| `DefaultVectorDimension` | `1536`  | Default embedding dimension                   |
| `HnswM`                  | `16`    | HNSW M parameter                              |
| `HnswEfConstruction`     | `200`   | HNSW efConstruction parameter                 |

## Architecture

This binding talks to a **Dazzle / Valkey server reachable over TCP**.
Unlike the iOS / Android SDKs that embed Valkey in-process, the .NET
target is for ASP.NET Core servers that already run a Valkey or
Dazzle sidecar (Docker, k8s).

If you need an *embedded* in-process surface from .NET — without a
Valkey sidecar — file an issue; the `libdazzle_lite` shared library
that powers Flutter Desktop / RN Desktop is a candidate, just needs
a P/Invoke wrapper.

## Sample

A minimal ASP.NET Core 9 sample that seeds a small product catalog
with mock embeddings and exposes `POST /search` lives at
[`samples/dotnet-vector-search`](../../samples/dotnet-vector-search).

## Reporting an issue

[https://github.com/IvanAliaga/dazzle-sdk/issues](https://github.com/IvanAliaga/dazzle-sdk/issues)
