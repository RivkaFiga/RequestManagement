using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// T-401 smoke test (R8.5): the fixture provides a real, migrated SQL Server and the in-process API reads
/// the same database. It runs on whichever path the environment selects (Testcontainers, or TEST_SQL_CONNECTION).
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class SqlServerFixtureSmokeTests(SqlServerFixture sqlServer) : IAsyncLifetime
{
    private const string DatabaseKey = "FixtureSmoke";

    private string _connectionString = null!;
    private ApiFactory _factory = null!;
    private HttpClient _client = null!;

    public async Task InitializeAsync()
    {
        _connectionString = await sqlServer.GetSharedDatabaseAsync(DatabaseKey, TestRequests.MigrateAsync);
        _factory = new ApiFactory(_connectionString);
        _client = _factory.CreateClient();
    }

    public Task DisposeAsync()
    {
        _client.Dispose();
        _factory.Dispose();
        return Task.CompletedTask;
    }

    [Fact]
    public async Task Fixture_ProvidesAnIsolatedSqlServerDatabase_WithAllMigrationsApplied()
    {
        var database = new SqlConnectionStringBuilder(_connectionString).InitialCatalog;
        Assert.StartsWith($"RequestManagement_Tests_{DatabaseKey}_", database);

        await using var db = TestRequests.CreateContext(_connectionString);
        Assert.True(await db.Database.CanConnectAsync());
        Assert.Empty(await db.Database.GetPendingMigrationsAsync());
        var applied = (await db.Database.GetAppliedMigrationsAsync()).ToList();
        Assert.Contains(applied, m => m.EndsWith("_InitialCreate", StringComparison.Ordinal));
        Assert.Contains(applied, m => m.EndsWith("_AddQueryIndexes", StringComparison.Ordinal));
        Assert.StartsWith("Microsoft SQL Server", await ScalarAsync(db, "SELECT @@VERSION"));
    }

    [Fact]
    public async Task Api_ReadsARowThatTheTestInsertedIntoTheSameDatabase()
    {
        var created = Assert.Single(await TestRequests.CreateAsync(_connectionString, "Fixture smoke", RequestStatus.Waiting, RequestPriority.High));

        var response = await _client.GetAsync($"/api/requests/{created.Id}");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(created.Title, body.GetProperty("title").GetString());
        Assert.Equal("Waiting", body.GetProperty("status").GetString());
        Assert.Equal("High", body.GetProperty("priority").GetString());
        Assert.Equal(Convert.ToBase64String(created.Version), body.GetProperty("rowVersion").GetString());
    }

    private static async Task<string> ScalarAsync(DbContext db, string sql)
    {
        var connection = db.Database.GetDbConnection();
        await db.Database.OpenConnectionAsync();
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            return Convert.ToString(await command.ExecuteScalarAsync()) ?? string.Empty;
        }
        finally
        {
            await db.Database.CloseConnectionAsync();
        }
    }
}
