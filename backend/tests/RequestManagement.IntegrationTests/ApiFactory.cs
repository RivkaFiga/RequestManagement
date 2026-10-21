using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// Hosts the real API in-process against an explicit test database. The connection string is
/// added as the last configuration source, so it wins over user-secrets and environment variables:
/// a developer's connection string (the seeded development database) is never used by tests.
/// </summary>
public sealed class ApiFactory(string connectionString) : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder) =>
        builder.ConfigureAppConfiguration((_, configuration) =>
            configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:RequestManagement"] = connectionString,
            }));
}
