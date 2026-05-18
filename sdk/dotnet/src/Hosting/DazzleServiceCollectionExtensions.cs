using System;
using Microsoft.Extensions.DependencyInjection;

namespace Dazzle.Hosting;

/// <summary>
/// Extension methods for registering Dazzle services in ASP.NET Core DI.
/// </summary>
public static class DazzleServiceCollectionExtensions
{
    /// <summary>
    /// Register <see cref="IDazzleClient"/> as a singleton, configured from <see cref="DazzleOptions"/>.
    /// </summary>
    public static IServiceCollection AddDazzle(
        this IServiceCollection services,
        Action<DazzleOptions>? configure = null)
    {
        if (services == null)
            throw new ArgumentNullException(nameof(services));

        var options = new DazzleOptions();
        configure?.Invoke(options);

        services.AddSingleton(options);
        services.AddSingleton<IDazzleClient>(sp =>
        {
            var opts = sp.GetRequiredService<DazzleOptions>();
            var client = new DazzleClient();
            _ = client.ConnectAsync(opts.Port, opts.Password);
            return client;
        });

        return services;
    }
}

/// <summary>
/// Configuration for the Dazzle / Valkey connection.
/// </summary>
public class DazzleOptions
{
    /// <summary>Port number for the Dazzle / Valkey server (default: 6379).</summary>
    public int Port { get; set; } = 6379;

    /// <summary>
    /// AUTH password for the Dazzle / Valkey server. Null or empty disables auth
    /// (suitable for localhost dev). In production, source from an environment
    /// variable or secrets manager — never hard-code.
    /// </summary>
    public string? Password { get; set; }

    /// <summary>Default vector dimension for new indices (default: 1536).</summary>
    public int DefaultVectorDimension { get; set; } = 1536;

    /// <summary>HNSW M parameter (default 16).</summary>
    public int HnswM { get; set; } = 16;

    /// <summary>HNSW efConstruction parameter (default 200).</summary>
    public int HnswEfConstruction { get; set; } = 200;
}
