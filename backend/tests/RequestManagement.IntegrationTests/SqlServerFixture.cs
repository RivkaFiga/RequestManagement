using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using RequestManagement.Infrastructure.Persistence;
using Testcontainers.MsSql;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// One real SQL Server per test run (plan §6.2, decision D11).
/// Primary path: a Testcontainers SQL Server 2022 container (needs Docker).
/// Alternative: if TEST_SQL_CONNECTION is set (e.g. SQL Server Express / LocalDB), a uniquely
/// named database <c>RequestManagement_Tests_&lt;guid&gt;</c> is used there and dropped afterwards.
/// </summary>
public sealed class SqlServerFixture : IAsyncLifetime
{
    private MsSqlContainer? _container;

    public string ConnectionString { get; private set; } = string.Empty;

    public async Task InitializeAsync()
    {
        var external = Environment.GetEnvironmentVariable("TEST_SQL_CONNECTION");
        string serverConnection;
        if (!string.IsNullOrWhiteSpace(external))
        {
            serverConnection = external;
        }
        else
        {
            _container = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")
                .Build();
            await _container.StartAsync();
            serverConnection = _container.GetConnectionString();
        }

        ConnectionString = new SqlConnectionStringBuilder(serverConnection)
        {
            InitialCatalog = $"RequestManagement_Tests_{Guid.NewGuid():N}",
            TrustServerCertificate = true,
        }.ConnectionString;
    }

    public AppDbContext CreateContext() =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(ConnectionString).Options);

    public async Task DisposeAsync()
    {
        if (_container is not null)
        {
            await _container.DisposeAsync();
            return;
        }

        await using var db = CreateContext();
        await db.Database.EnsureDeletedAsync();
    }
}

[CollectionDefinition(Name)]
public sealed class SqlServerCollection : ICollectionFixture<SqlServerFixture>
{
    public const string Name = "SQL Server";
}
