using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Dazzle;

/// <summary>
/// Async interface for Dazzle in-process vector search and cache operations.
/// </summary>
public interface IDazzleClient : IDisposable
{
    /// <summary>
    /// Connect to the Dazzle / Valkey server. Sends AUTH if password is provided.
    /// </summary>
    Task<bool> ConnectAsync(int port = 6379, string? password = null);

    /// <summary>
    /// Disconnect from the Dazzle server.
    /// </summary>
    Task DisconnectAsync();

    /// <summary>
    /// Execute a raw command and return the response as a string.
    /// </summary>
    Task<string?> ExecuteCommandAsync(string command, params string[] args);

    /// <summary>
    /// Set a hash field with a value.
    /// </summary>
    Task<bool> HashSetAsync(string key, string field, string value);

    /// <summary>
    /// Get a hash field value.
    /// </summary>
    Task<string?> HashGetAsync(string key, string field);

    /// <summary>
    /// Get all fields and values in a hash.
    /// </summary>
    Task<Dictionary<string, string>> HashGetAllAsync(string key);

    /// <summary>
    /// Create a vector search index (SQ8 — int8 with cosine metric).
    /// </summary>
    Task<bool> CreateVectorIndexSq8Async(
        string indexName,
        int dimension,
        int M = 16,
        int efConstruction = 200,
        int initialCapacity = 10000,
        bool rerank = false);

    /// <summary>
    /// Create a vector search index (FP16).
    /// </summary>
    Task<bool> CreateVectorIndexFp16Async(
        string indexName,
        int dimension,
        int M = 16,
        int efConstruction = 200,
        int initialCapacity = 10000);

    /// <summary>
    /// Add a single vector to an index.
    /// </summary>
    Task<bool> AddVectorAsync(string indexName, string vectorId, float[] embedding);

    /// <summary>
    /// Batch add vectors to an index.
    /// </summary>
    Task<bool> AddVectorBatchAsync(
        string indexName,
        string[] vectorIds,
        float[][] embeddings);

    /// <summary>
    /// Search the vector index for k nearest neighbors.
    /// </summary>
    Task<VectorSearchResult[]> SearchVectorAsync(
        string indexName,
        float[] queryEmbedding,
        int k = 10,
        int? ef = null);

    /// <summary>
    /// Get the health status of the Dazzle server.
    /// </summary>
    Task<bool> IsHealthyAsync();
}

public class VectorSearchResult
{
    public required string VectorId { get; set; }
    public required float Distance { get; set; }
}
