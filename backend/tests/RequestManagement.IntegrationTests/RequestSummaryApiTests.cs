using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// T-204 (R1.6, A4). Each test class database is a throw-away database created by the fixture and filled with a
/// known distribution through EF Core (the seeder is not used). Expected values come from the known distribution
/// and from independent, hand-written GROUP BY SQL executed on the same database.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class RequestSummaryApiTests(SqlServerFixture sqlServer)
{
    private static readonly DateTime Created = new(2026, 9, 1, 8, 0, 0, DateTimeKind.Utc);

    // (status, priority, number of rows): 12 rows in total; Waiting is unused on purpose (a group SQL omits).
    private static readonly (RequestStatus Status, RequestPriority Priority, int Rows)[] Distribution =
    [
        (RequestStatus.New, RequestPriority.High, 3),
        (RequestStatus.New, RequestPriority.Medium, 2),
        (RequestStatus.InProgress, RequestPriority.High, 1),
        (RequestStatus.InProgress, RequestPriority.Low, 4),
        (RequestStatus.Completed, RequestPriority.Medium, 2),
    ];

    [Fact]
    public async Task Summary_HasTheDocumentedShape_AndTheKnownCounts()
    {
        var connectionString = await sqlServer.GetSharedDatabaseAsync("Summary", SeedKnownDistributionAsync);
        using var factory = new ApiFactory(connectionString);
        using var client = factory.CreateClient();

        using var response = await client.GetAsync("/api/requests/summary");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var root = await response.Content.ReadFromJsonAsync<JsonElement>();

        Assert.Equal(12, root.GetProperty("total").GetInt32());
        Assert.EndsWith("Z", root.GetProperty("generatedAt").GetString());
        Assert.Equal(
            new[] { "New=5", "InProgress=5", "Waiting=0", "Completed=2" },
            Pairs(root, "byStatus", "status"));
        Assert.Equal(
            new[] { "Low=4", "Medium=4", "High=4" },
            Pairs(root, "byPriority", "priority"));
    }

    [Fact]
    public async Task Summary_MatchesDirectSql_AndAddsUpToTheTotal()
    {
        var connectionString = await sqlServer.GetSharedDatabaseAsync("Summary", SeedKnownDistributionAsync);
        using var factory = new ApiFactory(connectionString);
        using var client = factory.CreateClient();

        var root = await client.GetFromJsonAsync<JsonElement>("/api/requests/summary");

        var sqlTotal = await ScalarAsync(connectionString, "SELECT COUNT(*) FROM [Requests]");
        var sqlByStatus = await GroupedAsync(connectionString, "SELECT [Status], COUNT(*) FROM [Requests] GROUP BY [Status]");
        var sqlByPriority = await GroupedAsync(connectionString, "SELECT [Priority], COUNT(*) FROM [Requests] GROUP BY [Priority]");

        var apiByStatus = Counts(root, "byStatus", "status", Enum.Parse<RequestStatus>);
        var apiByPriority = Counts(root, "byPriority", "priority", Enum.Parse<RequestPriority>);

        Assert.Equal(sqlTotal, root.GetProperty("total").GetInt32());
        Assert.Equal(sqlTotal, apiByStatus.Values.Sum());
        Assert.Equal(sqlTotal, apiByPriority.Values.Sum());

        // Every group that SQL returns has the same count in the API; groups SQL omits are 0 in the API.
        foreach (var status in Enum.GetValues<RequestStatus>())
        {
            Assert.Equal(sqlByStatus.GetValueOrDefault((byte)status), apiByStatus[(int)status]);
        }

        foreach (var priority in Enum.GetValues<RequestPriority>())
        {
            Assert.Equal(sqlByPriority.GetValueOrDefault((byte)priority), apiByPriority[(int)priority]);
        }
    }

    [Fact]
    public async Task Summary_ReflectsAChangeMadeToTheDatabase_WhenTheCacheIsDisabled()
    {
        // Own database: this test mutates data, directly and behind the API's back, so the cache is switched off
        // (SummaryCache:Enabled=false). With the cache on, see RequestSummaryCacheApiTests.
        var connectionString = sqlServer.CreateIsolatedConnectionString("SummaryChange");
        await SeedKnownDistributionAsync(connectionString);
        using var factory = new ApiFactory(connectionString, new Dictionary<string, string?> { ["SummaryCache:Enabled"] = "false" });
        using var client = factory.CreateClient();

        var before = await client.GetFromJsonAsync<JsonElement>("/api/requests/summary");

        await using (var db = CreateContext(connectionString))
        {
            var row = await db.Requests.FirstAsync(r => r.Status == RequestStatus.New);
            row.Status = RequestStatus.Waiting;
            await db.SaveChangesAsync();
        }

        var after = await client.GetFromJsonAsync<JsonElement>("/api/requests/summary");

        Assert.Equal(before.GetProperty("total").GetInt32(), after.GetProperty("total").GetInt32());
        var b = Counts(before, "byStatus", "status", Enum.Parse<RequestStatus>);
        var a = Counts(after, "byStatus", "status", Enum.Parse<RequestStatus>);
        Assert.Equal(b[(int)RequestStatus.New] - 1, a[(int)RequestStatus.New]);
        Assert.Equal(b[(int)RequestStatus.Waiting] + 1, a[(int)RequestStatus.Waiting]);
    }

    private static async Task SeedKnownDistributionAsync(string connectionString)
    {
        await using var db = CreateContext(connectionString);
        await db.Database.MigrateAsync();

        var n = 0;
        foreach (var (status, priority, rows) in Distribution)
        {
            for (var i = 0; i < rows; i++, n++)
            {
                db.Requests.Add(new Request
                {
                    Title = $"Summary request {n}",
                    OrganizationName = "Summary Test Ltd",
                    Status = status,
                    Priority = priority,
                    CreatedAt = Created,
                    UpdatedAt = Created,
                });
            }
        }

        await db.SaveChangesAsync();
    }

    private static AppDbContext CreateContext(string connectionString) =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connectionString).Options);

    private static async Task<int> ScalarAsync(string connectionString, string sql)
    {
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand(sql, connection);
        return Convert.ToInt32(await command.ExecuteScalarAsync(), CultureInfo.InvariantCulture);
    }

    /// <summary>Independent oracle: plain GROUP BY SQL (a constant statement), not EF Core.</summary>
    private static async Task<Dictionary<byte, int>> GroupedAsync(string connectionString, string sql)
    {
        var result = new Dictionary<byte, int>();
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            result[reader.GetByte(0)] = reader.GetInt32(1);
        }

        return result;
    }

    private static string[] Pairs(JsonElement root, string array, string key) =>
        root.GetProperty(array).EnumerateArray()
            .Select(e => $"{e.GetProperty(key).GetString()}={e.GetProperty("count").GetInt32()}")
            .ToArray();

    private static Dictionary<int, int> Counts<TEnum>(JsonElement root, string array, string key, Func<string, TEnum> parse)
        where TEnum : struct, Enum =>
        root.GetProperty(array).EnumerateArray().ToDictionary(
            e => Convert.ToInt32(parse(e.GetProperty(key).GetString()!), CultureInfo.InvariantCulture),
            e => e.GetProperty("count").GetInt32());
}
