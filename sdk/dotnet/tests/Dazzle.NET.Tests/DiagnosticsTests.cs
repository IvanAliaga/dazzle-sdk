using System;
using System.IO;
using System.Runtime.InteropServices;
using Xunit;
using Xunit.Abstractions;

namespace Dazzle.Tests;

public class DiagnosticsTests
{
    private readonly ITestOutputHelper _out;
    public DiagnosticsTests(ITestOutputHelper output) => _out = output;

    [Fact]
    public void BaseDir_ContainsLibdazzle()
    {
        var baseDir = AppContext.BaseDirectory;
        _out.WriteLine($"BaseDir: {baseDir}");

        var files = Directory.GetFiles(baseDir, "*dazzle*");
        foreach (var f in files)
            _out.WriteLine($"  Found: {f}");

        Assert.True(files.Length > 0, $"No dazzle native lib found in {baseDir}");
    }

    [Fact]
    public void NativeLibrary_CanLoad()
    {
        var baseDir = AppContext.BaseDirectory;
        var path = Path.Combine(baseDir, "libdazzle.dylib");

        if (!File.Exists(path))
            path = Path.Combine(baseDir, "libdazzle.so");

        _out.WriteLine($"Trying: {path}, exists={File.Exists(path)}");

        bool loaded = NativeLibrary.TryLoad(path, out var handle);
        _out.WriteLine($"Loaded: {loaded}, handle={handle}");
        Assert.True(loaded, $"Could not load native library at {path}");

        if (loaded) NativeLibrary.Free(handle);
    }

    [Fact]
    public async System.Threading.Tasks.Task DazzleClient_Ping()
    {
        using var client = new DazzleClient();
        try
        {
            var result = await client.ExecuteCommandAsync("PING");
            _out.WriteLine($"PING result: [{result}]");
            Assert.NotNull(result);
            Assert.Contains("PONG", result);
        }
        catch (Exception ex)
        {
            _out.WriteLine($"Exception: {ex.GetType().Name}: {ex.Message}");
            throw;
        }
    }
}
