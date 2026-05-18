using System.Threading.Tasks;
using Xunit;

namespace Dazzle.Tests;

public class DazzleClientTests : IAsyncLifetime
{
    private DazzleClient? _client;

    public async Task InitializeAsync()
    {
        _client = new DazzleClient();
        var connected = await _client.ConnectAsync(6379);
        Assert.True(connected, "Failed to connect to Dazzle server");
    }

    public async Task DisposeAsync()
    {
        if (_client != null)
        {
            await _client.DisconnectAsync();
            _client.Dispose();
        }
    }

    [Fact]
    public async Task Ping_ShouldReturnPong()
    {
        Assert.NotNull(_client);
        var result = await _client.ExecuteCommandAsync("PING");
        Assert.NotNull(result);
        Assert.Contains("PONG", result);
    }

    [Fact]
    public async Task HashSet_AndHashGet_ShouldRoundtrip()
    {
        Assert.NotNull(_client);

        var testKey = "test:hash";
        var field = "field1";
        var value = "value1";

        var setResult = await _client.HashSetAsync(testKey, field, value);
        Assert.True(setResult, "HSET should succeed");

        var getResult = await _client.HashGetAsync(testKey, field);
        Assert.Equal(value, getResult);
    }

    [Fact]
    public async Task IsHealthy_ShouldReturnTrue()
    {
        Assert.NotNull(_client);
        var healthy = await _client.IsHealthyAsync();
        Assert.True(healthy);
    }
}
