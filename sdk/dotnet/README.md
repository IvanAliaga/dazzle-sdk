# Dazzle.NET — Vector Search SDK for .NET 9

P/Invoke bindings to the Dazzle native library (Valkey fork with HNSW),
designed for ASP.NET Core 9 applications.

## Install

```bash
dotnet add package Dazzle.NET
```

## Quick Start

### 1. Register in DI

```csharp
using Dazzle;
using Dazzle.Hosting;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDazzle(opts =>
{
    opts.Port = 6379;
    opts.Password = Environment.GetEnvironmentVariable("DAZZLE_PASSWORD");
    opts.DefaultVectorDimension = 1536;
});
```

### 2. Inject and use

```csharp
public class CatalogService
{
    private readonly IDazzleClient _dazzle;

    public CatalogService(IDazzleClient dazzle) => _dazzle = dazzle;

    public async Task IndexAsync(IEnumerable<Product> products)
    {
        await _dazzle.CreateVectorIndexSq8Async(
            "catalog", dimension: 1536, M: 16, efConstruction: 200);

        var ids        = products.Select(p => p.Id.ToString()).ToArray();
        var embeddings = products.Select(p => p.Embedding).ToArray();
        await _dazzle.AddVectorBatchAsync("catalog", ids, embeddings);
    }

    public async Task<VectorSearchResult[]> SearchAsync(float[] query, int k = 5)
        => await _dazzle.SearchVectorAsync("catalog", query, k);
}
```

## Configuration

| Option                   | Default | Description                                   |
| ------------------------ | ------- | --------------------------------------------- |
| `Port`                   | `6379`  | Dazzle / Valkey server port                   |
| `Password`               | `null`  | AUTH password — source from a secrets manager |
| `DefaultVectorDimension` | `1536`  | Default embedding dimension                   |
| `HnswM`                  | `16`    | HNSW M parameter                              |
| `HnswEfConstruction`     | `200`   | HNSW efConstruction parameter                 |

## API

```csharp
public interface IDazzleClient : IDisposable
{
    Task<bool>    ConnectAsync(int port = 6379, string? password = null);
    Task          DisconnectAsync();
    Task<string?> ExecuteCommandAsync(string command, params string[] args);
    Task<bool>    IsHealthyAsync();

    // Hash operations
    Task<bool>                          HashSetAsync(string key, string field, string value);
    Task<string?>                       HashGetAsync(string key, string field);
    Task<Dictionary<string, string>>    HashGetAllAsync(string key);

    // Vector index management
    Task<bool> CreateVectorIndexSq8Async (string indexName, int dimension, int M = 16, int efConstruction = 200, int initialCapacity = 10000, bool rerank = false);
    Task<bool> CreateVectorIndexFp16Async(string indexName, int dimension, int M = 16, int efConstruction = 200, int initialCapacity = 10000);

    // Vector ops
    Task<bool>                  AddVectorAsync     (string indexName, string vectorId, float[] embedding);
    Task<bool>                  AddVectorBatchAsync(string indexName, string[] vectorIds, float[][] embeddings);
    Task<VectorSearchResult[]>  SearchVectorAsync  (string indexName, float[] query, int k = 10, int? ef = null);
}
```

## Supported runtimes

| RID            | Native binary       |
| -------------- | ------------------- |
| `linux-x64`    | `libdazzle.so`      |
| `linux-arm64`  | `libdazzle.so`      |
| `osx-arm64`    | `libdazzle.dylib`   |
| `win-x64`      | `dazzle.dll`        |

The MSBuild targets shipped in the package copy the right binary for the
consuming project's runtime to its output directory automatically.

## Sample

A minimal ASP.NET Core 9 sample lives at
[`samples/dotnet-vector-search`](https://github.com/IvanAliaga/dazzle/tree/main/samples/dotnet-vector-search) —
register Dazzle, seed a small catalog with mock embeddings, and expose
`POST /search`.

## License

Apache 2.0.
