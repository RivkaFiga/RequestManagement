using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// Hosts the real API in-process against an explicit test database. The connection string is
/// added as the last configuration source, so it wins over user-secrets and environment variables:
/// a developer's connection string (the seeded development database) is never used by tests.
/// <para>
/// <paramref name="settings"/> adds further configuration values (e.g. <c>SummaryCache:Enabled</c>) and
/// <paramref name="configureServices"/> adjusts the services after the application's own registrations (e.g. to add
/// an EF Core interceptor or a manual clock).
/// </para>
/// </summary>
public sealed class ApiFactory(
    string connectionString,
    IReadOnlyDictionary<string, string?>? settings = null,
    Action<IServiceCollection>? configureServices = null) : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.ConfigureAppConfiguration((_, configuration) =>
        {
            configuration.AddInMemoryCollection(settings ?? new Dictionary<string, string?>());
            configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:RequestManagement"] = connectionString,
            });
        });

        if (configureServices is not null)
        {
            builder.ConfigureServices(configureServices);
        }
    }
}
