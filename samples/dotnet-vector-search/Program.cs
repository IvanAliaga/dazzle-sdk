// Minimal ASP.NET Core 9 sample: vector search over a small product catalog.
// Demonstrates registering Dazzle in DI, creating an HNSW index, indexing
// items with mock embeddings, and exposing a /search endpoint.
//
// In production, replace GenerateMockEmbedding with a real embeddings API
// call (OpenAI text-embedding-3-small, Cohere embed-v4, etc.).

using System.Security.Cryptography;
using System.Text;
using Dazzle;
using Dazzle.Hosting;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.AddConsole();

builder.Services.AddDazzle(opts =>
{
    opts.Port = 6379;
    opts.DefaultVectorDimension = 1536;
});

builder.Services.AddSingleton<CatalogIndexer>();

var app = builder.Build();

// Seed the index on startup
var indexer = app.Services.GetRequiredService<CatalogIndexer>();
_ = indexer.SeedAsync();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapPost("/search", async (SearchRequest req, CatalogIndexer idx) =>
{
    var hits = await idx.SearchAsync(req.Query, topK: req.TopK ?? 3);
    return Results.Ok(hits);
});

app.Run();

// ---------------------------------------------------------------------------

public sealed class CatalogIndexer
{
    private const string IndexName = "catalog";

    private readonly IDazzleClient _dazzle;
    private readonly ILogger<CatalogIndexer> _log;

    public CatalogIndexer(IDazzleClient dazzle, ILogger<CatalogIndexer> log)
    {
        _dazzle = dazzle;
        _log    = log;
    }

    public async Task SeedAsync()
    {
        try
        {
            await _dazzle.CreateVectorIndexSq8Async(
                IndexName, dimension: 1536, M: 16,
                efConstruction: 200, initialCapacity: 1000);

            var products = SampleProducts();
            var ids        = products.Select(p => p.Id.ToString()).ToArray();
            var embeddings = products.Select(p => MockEmbed($"{p.Name} {p.Description}")).ToArray();

            await _dazzle.AddVectorBatchAsync(IndexName, ids, embeddings);

            // Stash payloads in a hash so /search can return them
            foreach (var p in products)
            {
                var json = System.Text.Json.JsonSerializer.Serialize(p);
                await _dazzle.HashSetAsync("catalog:meta", p.Id.ToString(), json);
            }

            _log.LogInformation("Seeded {N} products into '{Index}'", products.Count, IndexName);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to seed catalog");
        }
    }

    public async Task<SearchHit[]> SearchAsync(string query, int topK)
    {
        var qEmbedding = MockEmbed(query);
        var raw = await _dazzle.SearchVectorAsync(IndexName, qEmbedding, k: topK);

        var hits = new List<SearchHit>(raw.Length);
        foreach (var r in raw)
        {
            var meta = await _dazzle.HashGetAsync("catalog:meta", r.VectorId);
            hits.Add(new SearchHit(r.VectorId, r.Distance, meta));
        }
        return hits.ToArray();
    }

    private static float[] MockEmbed(string text)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        var v = new float[1536];
        for (int i = 0; i < v.Length; i++)
            v[i] = (hash[i % hash.Length] - 128) / 256f;

        var norm = (float)Math.Sqrt(v.Sum(x => x * x));
        for (int i = 0; i < v.Length; i++) v[i] /= norm;
        return v;
    }

    private static List<Product> SampleProducts() =>
    [
        new(0, "Laptop ASUS",            "Intel i7, 16GB RAM, 512GB SSD"),
        new(1, "Wireless mouse",         "Logitech MX Master, 2.4GHz"),
        new(2, "Mechanical keyboard",    "Corsair K95, RGB, Cherry MX"),
        new(3, "4K monitor",             "27 inch, 60Hz, HDMI + DP"),
        new(4, "HD webcam",              "1080p, integrated mic, USB"),
        new(5, "USB-C hub",              "7 ports, fast charge, Thunderbolt 3"),
        new(6, "Laptop sleeve",          "Neoprene, 15.6 inch, water-resistant"),
        new(7, "HDMI cable",             "2.1, 4K@60Hz, 2 m"),
        new(8, "Laptop stand",           "Aluminum, adjustable, vented"),
        new(9, "Power adapter",          "100W, USB-C, universal"),
    ];
}

public record Product(int Id, string Name, string Description);

public record SearchRequest(string Query, int? TopK);

public record SearchHit(string Id, float Distance, string? Payload);
