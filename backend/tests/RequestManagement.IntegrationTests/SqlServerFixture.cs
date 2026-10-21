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
    private readonly object _gate = new();
    private readonly List<string> _isolatedDatabases = [];
    private readonly Dictionary<string, Task<string>> _sharedDatabases = [];
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

    /// <summary>
    /// A connection string for a new, uniquely named database on the same server. The database is
    /// dropped on disposal, so tests never touch any other database (in particular not the development one).
    /// </summary>
    public string CreateIsolatedConnectionString(string purpose)
    {
        var name = $"RequestManagement_Tests_{purpose}_{Guid.NewGuid():N}";
        lock (_gate)
        {
            _isolatedDatabases.Add(name);
        }

        return new SqlConnectionStringBuilder(ConnectionString) { InitialCatalog = name }.ConnectionString;
    }

    /// <summary>
    /// An isolated database that is initialized once per test run (e.g. seeded read-only data)
    /// and shared by every test that asks for the same <paramref name="key"/>.
    /// </summary>
    public Task<string> GetSharedDatabaseAsync(string key, Func<string, Task> initialize)
    {
        lock (_gate)
        {
            if (!_sharedDatabases.TryGetValue(key, out var shared))
            {
                shared = InitializeSharedAsync(CreateIsolatedConnectionString(key), initialize);
                _sharedDatabases[key] = shared;
            }

            return shared;
        }
    }

    private static async Task<string> InitializeSharedAsync(string connectionString, Func<string, Task> initialize)
    {
        await initialize(connectionString);
        return connectionString;
    }

    public async Task DisposeAsync()
    {
        if (_container is not null)
        {
            await _container.DisposeAsync();
            return;
        }

        await using var db = CreateContext();
        await db.Database.EnsureDeletedAsync();

        foreach (var name in _isolatedDatabases)
        {
            var connection = new SqlConnectionStringBuilder(ConnectionString) { InitialCatalog = name }.ConnectionString;
            await using var isolated = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connection).Options);
            await isolated.Database.EnsureDeletedAsync();
        }
    }
}

[CollectionDefinition(Name)]
public sealed class SqlServerCollection : ICollectionFixture<SqlServerFixture>
{
    public const string Name = "SQL Server";
}
