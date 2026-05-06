using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Dazzle.Native;

namespace Dazzle;

public sealed class DazzleClient : IDazzleClient
{
    private bool _disposed;

    public async Task<bool> ConnectAsync(int port = 6379, string? password = null)
    {
        if (!string.IsNullOrEmpty(password))
        {
            var authReply = await ExecuteCommandAsync("AUTH", password);
            if (authReply == null || authReply.StartsWith("-"))
                return false;
        }
        return await IsHealthyAsync();
    }

    public Task DisconnectAsync() => Task.CompletedTask;

    public async Task<string?> ExecuteCommandAsync(string command, params string[] args)
    {
        ThrowIfDisposed();

        var argv = new string[args.Length + 1];
        argv[0] = command;
        Array.Copy(args, 0, argv, 1, args.Length);

        var result = LibDazzle.dazzle_direct_command(argv.Length, argv);
        if (result == 0)
            return null;

        try
        {
            return await Task.FromResult(Marshal.PtrToStringUTF8(result));
        }
        finally
        {
            LibDazzle.dazzle_free_result(result);
        }
    }

    // Parse a single RESP value from a raw RESP reply.
    // Handles: +simple, -error, :integer, $bulk
    private static string? ParseRespValue(string? raw)
    {
        if (raw == null) return null;
        var s = raw.TrimEnd('\r', '\n');
        if (s.Length == 0) return null;

        char type = s[0];
        if (type == '+' || type == ':') return s.Substring(1);
        if (type == '-') return null;  // error → null
        if (type == '$')
        {
            // $N\r\nDATA
            int nl = s.IndexOf('\n');
            if (nl < 0) return s.Substring(1); // no header — return as-is
            int len = int.TryParse(s.Substring(1, nl - 2), out int n) ? n : -1;
            if (len < 0) return null;           // $-1 = nil
            return s.Substring(nl + 1);         // data after \n
        }
        return s;
    }

    public async Task<bool> HashSetAsync(string key, string field, string value)
    {
        var result = await ExecuteCommandAsync("HSET", key, field, value);
        return result != null && !result.StartsWith("-");
    }

    public async Task<string?> HashGetAsync(string key, string field)
    {
        var raw = await ExecuteCommandAsync("HGET", key, field);
        return ParseRespValue(raw);
    }

    public async Task<Dictionary<string, string>> HashGetAllAsync(string key)
    {
        var raw = await ExecuteCommandAsync("HGETALL", key);
        var dict = new Dictionary<string, string>();

        if (string.IsNullOrEmpty(raw) || raw.StartsWith("-"))
            return dict;

        // Multi-bulk: *N\r\n then alternating $len\r\ndata\r\n pairs
        var lines = raw.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries);
        int i = 0;
        if (i < lines.Length && lines[i].StartsWith("*")) i++; // skip *N header

        while (i + 3 < lines.Length)
        {
            // lines[i]   = $len of key
            // lines[i+1] = key data
            // lines[i+2] = $len of value
            // lines[i+3] = value data
            var fieldName  = lines[i + 1];
            var fieldValue = lines[i + 3];
            dict[fieldName] = fieldValue;
            i += 4;
        }

        return dict;
    }

    public async Task<bool> CreateVectorIndexSq8Async(
        string indexName, int dimension, int M = 16,
        int efConstruction = 200, int initialCapacity = 10000, bool rerank = false)
    {
        ThrowIfDisposed();
        try
        {
            var handle = LibDazzle.dazzle_vs_create_sq8(
                indexName, dimension, M, efConstruction, initialCapacity, rerank ? 1 : 0);
            return await Task.FromResult(handle != 0);
        }
        catch { return false; }
    }

    public async Task<bool> CreateVectorIndexFp16Async(
        string indexName, int dimension, int M = 16,
        int efConstruction = 200, int initialCapacity = 10000)
    {
        ThrowIfDisposed();
        try
        {
            var handle = LibDazzle.dazzle_vs_create_f16(
                indexName, dimension, M, efConstruction, initialCapacity);
            return await Task.FromResult(handle != 0);
        }
        catch { return false; }
    }

    public async Task<bool> AddVectorAsync(string indexName, string vectorId, float[] embedding)
    {
        ThrowIfDisposed();
        try
        {
            LibDazzle.dazzle_vs_add_direct(indexName, vectorId, -1, embedding);
            return await Task.FromResult(true);
        }
        catch { return false; }
    }

    public async Task<bool> AddVectorBatchAsync(
        string indexName, string[] vectorIds, float[][] embeddings)
    {
        ThrowIfDisposed();

        if (vectorIds.Length != embeddings.Length)
            throw new ArgumentException("vectorIds and embeddings length mismatch");

        try
        {
            int dim = embeddings.Length > 0 ? embeddings[0].Length : 0;
            var flat = new float[vectorIds.Length * dim];
            for (int i = 0; i < vectorIds.Length; i++)
                Array.Copy(embeddings[i], 0, flat, i * dim, dim);

            LibDazzle.dazzle_vs_add_batch_direct(indexName, vectorIds.Length, vectorIds, null, flat);
            return await Task.FromResult(true);
        }
        catch { return false; }
    }

    public async Task<VectorSearchResult[]> SearchVectorAsync(
        string indexName, float[] queryEmbedding, int k = 10, int? ef = null)
    {
        ThrowIfDisposed();
        try
        {
            var outIds = new nint[k];
            var outDists = new float[k];

            int count = LibDazzle.dazzle_vs_search_direct(
                indexName, queryEmbedding, k, ef ?? -1, outIds, outDists, k);

            var results = new VectorSearchResult[count];
            for (int i = 0; i < count; i++)
            {
                var idStr = Marshal.PtrToStringUTF8(outIds[i]);
                if (idStr != null)
                {
                    results[i] = new VectorSearchResult { VectorId = idStr, Distance = outDists[i] };
                    LibDazzle.dazzle_vs_free_id(outIds[i]);
                }
            }

            return await Task.FromResult(results);
        }
        catch { return Array.Empty<VectorSearchResult>(); }
    }

    public async Task<bool> IsHealthyAsync()
    {
        try
        {
            var result = await ExecuteCommandAsync("PING");
            return result != null && (result.Contains("PONG") || result == "+OK");
        }
        catch { return false; }
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _disposed = true;
            GC.SuppressFinalize(this);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
            throw new ObjectDisposedException(nameof(DazzleClient));
    }
}
