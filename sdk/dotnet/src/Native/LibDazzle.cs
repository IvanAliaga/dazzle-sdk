using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Dazzle.Native;

internal static partial class LibDazzle
{
    // LibName is "libdazzle" — matches the DLL name used in [LibraryImport].
    // The resolver strips the "lib" prefix when constructing on-disk paths.
    private const string LibName = "libdazzle";

    static LibDazzle()
    {
        NativeLibrary.SetDllImportResolver(typeof(LibDazzle).Assembly, ResolveDazzleLibrary);
    }

    private static IntPtr ResolveDazzleLibrary(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != LibName)
            return IntPtr.Zero;

        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, $"{LibName}.so"),
            Path.Combine(baseDir, $"{LibName}.dll"),
            Path.Combine(baseDir, $"{LibName}.dylib"),
            Path.Combine("/usr/lib", $"{LibName}.so"),
            Path.Combine("/usr/local/lib", $"{LibName}.so"),
        };

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                try { return NativeLibrary.Load(candidate); }
                catch { /* try next */ }
            }
        }

        return NativeLibrary.Load(LibName);
    }

    // Direct command: argc/argv → malloc'd response string (free with dazzle_free_result)
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial nint dazzle_direct_command(int argc, string[] argv_strs);

    // Free result string from dazzle_direct_command
    [LibraryImport(LibName)]
    public static partial void dazzle_free_result(nint result);

    // Create SQ8 vector index (int8 + cosine). Returns opaque handle or 0 on failure.
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial nint dazzle_vs_create_sq8(string name, int dim, int M, int efC, int initialCap, int rerank);

    // Create FP16 vector index. Returns opaque handle or 0 on failure.
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial nint dazzle_vs_create_f16(string name, int dim, int M, int efC, int initialCap);

    // Resolve index name to handle. Returns 0 when index not found.
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial nint dazzle_vs_open_handle(string name);

    // Add single vector
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial void dazzle_vs_add_direct(string name, string key, int key_len, float[] vec);

    // Batch add vectors
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial void dazzle_vs_add_batch_direct(
        string name,
        int n_vecs,
        string[] ids,
        int[]? id_lens,
        float[] vecs_flat);

    // Handle-based k-NN search. Returns count of results filled in out_ids/out_dists.
    [LibraryImport(LibName)]
    public static partial int dazzle_vs_search_handle(
        nint handle,
        float[] query,
        int k,
        int ef,
        nint[] out_ids,
        float[] out_dists,
        int max_out);

    // Name-resolving k-NN search (one call, validates handle atomically)
    [LibraryImport(LibName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int dazzle_vs_search_direct(
        string name,
        float[] query,
        int k,
        int ef,
        nint[] out_ids,
        float[] out_dists,
        int max_out);

    // Free id string returned by dazzle_vs_search_*
    [LibraryImport(LibName)]
    public static partial void dazzle_vs_free_id(nint id);
}
