using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// T-206 / IT-8 (R3.2, R2.1): <c>GET /api/requests/{id}/history</c> returns a JSON array of
/// <c>{id, requestId, previousStatus, newStatus, changedAt, changedBy}</c>, newest first; 404 for an unknown request.
/// Every test creates its own rows, so tests are independent. Expected values come from the rows the test wrote.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class RequestHistoryApiTests(SqlServerFixture sqlServer) : IAsyncLifetime
{
    private const string DatabaseKey = "History";

    private string _connectionString = null!;
    private ApiFactory _factory = null!;
    private HttpClient _client = null!;

    public async Task InitializeAsync()
    {
        _connectionString = await sqlServer.GetSharedDatabaseAsync(DatabaseKey, MigrateAsync);
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
    public async Task RequestWithoutChanges_Returns200AndAnEmptyArray()
    {
        var id = await CreateRequestAsync();

        using var response = await _client.GetAsync($"/api/requests/{id}/history");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(JsonValueKind.Array, body.ValueKind);
        Assert.Equal(0, body.GetArrayLength());
    }

    [Fact]
    public async Task ChangesMadeThroughTheApi_AreReturnedNewestFirst_WithTheDocumentedFields()
    {
        var id = await CreateRequestAsync();
        var version = await VersionAsync(id);
        version = await PatchAsync(id, "Waiting", version, "ann");
        version = await PatchAsync(id, "InProgress", version, "bob");
        await PatchAsync(id, "Completed", version, null);

        using var response = await _client.GetAsync($"/api/requests/{id}/history");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var items = body.EnumerateArray().ToArray();

        Assert.Equal(
            new[] { "InProgress>Completed", "Waiting>InProgress", "New>Waiting" },
            items.Select(e => $"{e.GetProperty("previousStatus").GetString()}>{e.GetProperty("newStatus").GetString()}").ToArray());
        Assert.Equal(new[] { "anonymous", "bob", "ann" }, items.Select(e => e.GetProperty("changedBy").GetString()).ToArray());

        // Exactly the documented properties, and the values match what is stored.
        var stored = await StoredHistoryAsync(id);
        Assert.Equal(
            new[] { "changedAt", "changedBy", "id", "newStatus", "previousStatus", "requestId" },
            items[0].EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).ToArray());
        Assert.Equal(stored.OrderByDescending(h => h.Id).Select(h => h.Id).ToArray(), items.Select(e => e.GetProperty("id").GetInt64()).ToArray());
        Assert.All(items, e => Assert.Equal(id, e.GetProperty("requestId").GetInt32()));
        Assert.All(items, e => Assert.EndsWith("Z", e.GetProperty("changedAt").GetString()));
        Assert.Equal(
            stored.OrderByDescending(h => h.Id).Select(h => h.ChangedAt).ToArray(),
            items.Select(e => e.GetProperty("changedAt").GetDateTime().ToUniversalTime()).ToArray());
        var times = items.Select(e => e.GetProperty("changedAt").GetDateTime()).ToArray();
        Assert.Equal(times.OrderByDescending(t => t).ToArray(), times);
    }

    [Fact]
    public async Task OrderIsByChangedAtDescending_NotByInsertionOrder()
    {
        var id = await CreateRequestAsync();
        var t = TruncateToMilliseconds(DateTime.UtcNow.AddHours(-3));
        // Inserted oldest-id-first with the newest timestamp in the middle.
        await InsertHistoryAsync(id, RequestStatus.New, RequestStatus.Waiting, t.AddMinutes(10), "a");
        await InsertHistoryAsync(id, RequestStatus.Waiting, RequestStatus.InProgress, t.AddMinutes(30), "b");
        await InsertHistoryAsync(id, RequestStatus.InProgress, RequestStatus.Completed, t.AddMinutes(20), "c");

        var users = await ChangedByInResponseAsync(id);

        Assert.Equal(new[] { "b", "c", "a" }, users);
    }

    [Fact]
    public async Task EntriesWithTheSameTimestamp_AreOrderedByNewestIdFirst_OnEveryCall()
    {
        var id = await CreateRequestAsync();
        var same = TruncateToMilliseconds(DateTime.UtcNow.AddHours(-2));
        await InsertHistoryAsync(id, RequestStatus.New, RequestStatus.Waiting, same, "first");
        await InsertHistoryAsync(id, RequestStatus.Waiting, RequestStatus.InProgress, same, "second");
        await InsertHistoryAsync(id, RequestStatus.InProgress, RequestStatus.Completed, same, "third");

        for (var i = 0; i < 3; i++)
        {
            Assert.Equal(new[] { "third", "second", "first" }, await ChangedByInResponseAsync(id));
        }
    }

    [Fact]
    public async Task OnlyTheHistoryOfTheRequestedRequest_IsReturned()
    {
        var mine = await CreateRequestAsync();
        var other = await CreateRequestAsync();
        await PatchAsync(mine, "Waiting", await VersionAsync(mine), "mine");
        await PatchAsync(other, "InProgress", await VersionAsync(other), "other");

        Assert.Equal(new[] { "mine" }, await ChangedByInResponseAsync(mine));
        Assert.Equal(new[] { "other" }, await ChangedByInResponseAsync(other));
    }

    [Fact]
    public async Task UnknownRequest_Returns404ProblemDetails()
    {
        using var response = await _client.GetAsync($"/api/requests/{int.MaxValue}/history");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(404, problem.GetProperty("status").GetInt32());
        Assert.Contains(int.MaxValue.ToString(), problem.GetProperty("detail").GetString());
    }

    [Fact]
    public async Task NonNumericId_Returns404()
    {
        using var response = await _client.GetAsync("/api/requests/abc/history");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    // ---------------------------------------------------------------- helpers

    private static async Task MigrateAsync(string connectionString)
    {
        await using var db = CreateContext(connectionString);
        await db.Database.MigrateAsync();
    }

    private static AppDbContext CreateContext(string connectionString) =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connectionString).Options);

    private static DateTime TruncateToMilliseconds(DateTime value) =>
        new(value.Ticks - value.Ticks % TimeSpan.TicksPerMillisecond, DateTimeKind.Utc);

    private async Task<int> CreateRequestAsync()
    {
        var created = TruncateToMilliseconds(DateTime.UtcNow.AddDays(-1));
        await using var db = CreateContext(_connectionString);
        var request = new Request
        {
            Title = $"History test {Guid.NewGuid():N}",
            OrganizationName = "History Test Ltd",
            Status = RequestStatus.New,
            Priority = RequestPriority.Low,
            CreatedAt = created,
            UpdatedAt = created,
        };
        db.Requests.Add(request);
        await db.SaveChangesAsync();
        return request.Id;
    }

    private async Task<string> VersionAsync(int id)
    {
        await using var db = CreateContext(_connectionString);
        return Convert.ToBase64String((await db.Requests.AsNoTracking().SingleAsync(r => r.Id == id)).Version);
    }

    /// <summary>A real status change through the API; returns the new row version.</summary>
    private async Task<string> PatchAsync(int id, string status, string rowVersion, string? changedBy)
    {
        var message = new HttpRequestMessage(HttpMethod.Patch, $"/api/requests/{id}/status")
        {
            Content = new StringContent(JsonSerializer.Serialize(new { status, rowVersion }), Encoding.UTF8, "application/json"),
        };
        if (changedBy is not null)
        {
            message.Headers.Add(ChangedBy.HeaderName, changedBy);
        }

        using var response = await _client.SendAsync(message);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("rowVersion").GetString()!;
    }

    private async Task InsertHistoryAsync(int requestId, RequestStatus from, RequestStatus to, DateTime changedAt, string changedBy)
    {
        await using var db = CreateContext(_connectionString);
        db.RequestStatusHistory.Add(new RequestStatusHistoryEntry
        {
            RequestId = requestId,
            PreviousStatus = from,
            NewStatus = to,
            ChangedAt = changedAt,
            ChangedBy = changedBy,
        });
        await db.SaveChangesAsync();
    }

    private async Task<List<RequestStatusHistoryEntry>> StoredHistoryAsync(int id)
    {
        await using var db = CreateContext(_connectionString);
        return await db.RequestStatusHistory.AsNoTracking().Where(h => h.RequestId == id).ToListAsync();
    }

    private async Task<string[]> ChangedByInResponseAsync(int id)
    {
        var body = await _client.GetFromJsonAsync<JsonElement>($"/api/requests/{id}/history");
        return body.EnumerateArray().Select(e => e.GetProperty("changedBy").GetString()!).ToArray();
    }
}
