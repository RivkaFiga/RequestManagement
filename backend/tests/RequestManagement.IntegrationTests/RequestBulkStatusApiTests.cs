using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// T-207 / IT-6 (R4.1-R4.3, R3.1, R8.2-R8.5). The API runs in-process against a real SQL Server database.
/// Every test creates its own rows and asserts only on them. Expected values are read back from the database with
/// plain EF Core queries, not from the API under test.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class RequestBulkStatusApiTests(SqlServerFixture sqlServer) : IAsyncLifetime
{
    private const string DatabaseKey = "BulkStatusUpdate";

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

    // ---------------------------------------------------------------- successful transitions

    [Fact]
    public async Task Success_UpdatesEveryItem_ReturnsTheNewVersions_AndRecordsOneCorrectHistoryRowEach()
    {
        var first = await CreateRequestAsync(RequestStatus.New);
        var second = await CreateRequestAsync(RequestStatus.Waiting);
        var before = new[] { await SnapshotAsync(first.Id), await SnapshotAsync(second.Id) };
        var sentAfter = TruncateToMilliseconds(DateTime.UtcNow);

        using var response = await PostAsync("InProgress", [first, second], changedBy: "dana");
        var receivedBefore = DateTime.UtcNow;

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal((2, 2, 0), (body.GetProperty("requested").GetInt32(), body.GetProperty("succeeded").GetInt32(), body.GetProperty("failed").GetInt32()));
        var results = body.GetProperty("results").EnumerateArray().ToArray();
        Assert.Equal([first.Id, second.Id], results.Select(r => r.GetProperty("id").GetInt32()));

        for (var i = 0; i < 2; i++)
        {
            var id = results[i].GetProperty("id").GetInt32();
            var after = await SnapshotAsync(id);
            Assert.Equal("Updated", results[i].GetProperty("outcome").GetString());
            Assert.Equal(JsonValueKind.Null, results[i].GetProperty("error").ValueKind);
            Assert.Equal(after.RowVersion, results[i].GetProperty("rowVersion").GetString());
            Assert.NotEqual(before[i].RowVersion, after.RowVersion);

            Assert.Equal(RequestStatus.InProgress, after.Status);
            Assert.True(after.UpdatedAt > before[i].UpdatedAt);
            Assert.InRange(after.UpdatedAt, sentAfter, receivedBefore);

            var entry = Assert.Single(after.History);
            Assert.Equal(id, entry.RequestId);
            Assert.Equal(before[i].Status, entry.PreviousStatus);
            Assert.Equal(RequestStatus.InProgress, entry.NewStatus);
            Assert.Equal("dana", entry.ChangedBy);
            Assert.Equal(after.UpdatedAt, entry.ChangedAt);
        }
    }

    [Fact]
    public async Task Success_ReturnedVersionsWorkForTheNextUpdate_AndTheHistoryKeepsEveryStep()
    {
        var created = await CreateRequestAsync(RequestStatus.New);

        var first = await BulkAsync("Waiting", [created]);
        var next = (created.Id, first.GetProperty("results")[0].GetProperty("rowVersion").GetString()!);
        var second = await BulkAsync("Completed", [next]);

        Assert.Equal("Updated", second.GetProperty("results")[0].GetProperty("outcome").GetString());
        var snapshot = await SnapshotAsync(created.Id);
        Assert.Equal(RequestStatus.Completed, snapshot.Status);
        Assert.Equal(
            new[] { (RequestStatus.New, RequestStatus.Waiting), (RequestStatus.Waiting, RequestStatus.Completed) },
            snapshot.History.Select(h => (h.PreviousStatus, h.NewStatus)).ToArray());
    }

    [Fact]
    public async Task Success_WithoutUserHeader_RecordsAnonymous()
    {
        var created = await CreateRequestAsync(RequestStatus.New);

        await BulkAsync("Waiting", [created]);

        Assert.Equal("anonymous", Assert.Single((await SnapshotAsync(created.Id)).History).ChangedBy);
    }

    // ---------------------------------------------------------------- per-item failures

    [Fact]
    public async Task MissingId_IsReportedAsNotFound_AndNothingIsCreated()
    {
        var missingId = int.MaxValue;

        var body = await BulkAsync("InProgress", [(missingId, Convert.ToBase64String(new byte[8]))]);

        Assert.Equal((1, 0, 1), Counts(body));
        var result = body.GetProperty("results")[0];
        Assert.Equal(missingId, result.GetProperty("id").GetInt32());
        Assert.Equal("NotFound", result.GetProperty("outcome").GetString());
        Assert.Contains(missingId.ToString(), result.GetProperty("error").GetString());
        Assert.Equal(JsonValueKind.Null, result.GetProperty("rowVersion").ValueKind);
        await using var db = CreateContext(_connectionString);
        Assert.False(await db.Requests.AnyAsync(r => r.Id == missingId));
        Assert.False(await db.RequestStatusHistory.AnyAsync(h => h.RequestId == missingId));
    }

    [Fact]
    public async Task StaleVersion_IsReportedAsConflict_WithTheCurrentVersion_AndNothingIsChanged()
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        await BulkAsync("InProgress", [created]); // someone else got there first
        var before = await SnapshotAsync(created.Id);

        var body = await BulkAsync("Waiting", [created], changedBy: "late-user");

        Assert.Equal((1, 0, 1), Counts(body));
        var result = body.GetProperty("results")[0];
        Assert.Equal("Conflict", result.GetProperty("outcome").GetString());
        Assert.Equal(before.RowVersion, result.GetProperty("rowVersion").GetString());
        Assert.False(string.IsNullOrWhiteSpace(result.GetProperty("error").GetString()));

        var after = await SnapshotAsync(created.Id);
        Assert.Equal(before, after, SnapshotComparer.Instance);
        Assert.DoesNotContain(after.History, h => h.ChangedBy == "late-user");
    }

    [Theory]
    [InlineData(RequestStatus.Completed, "InProgress")] // Completed is terminal
    [InlineData(RequestStatus.New, "New")] // the same status is not a transition
    [InlineData(RequestStatus.New, "Completed")] // must go through InProgress or Waiting
    [InlineData(RequestStatus.InProgress, "New")]
    public async Task DisallowedTransition_IsReportedAsInvalidTransition_NamesIt_AndChangesNothing(RequestStatus current, string target)
    {
        var created = await CreateRequestAsync(current);
        var before = await SnapshotAsync(created.Id);

        var body = await BulkAsync(target, [created]);

        Assert.Equal((1, 0, 1), Counts(body));
        var result = body.GetProperty("results")[0];
        Assert.Equal("InvalidTransition", result.GetProperty("outcome").GetString());
        var error = result.GetProperty("error").GetString();
        Assert.Contains(current.ToString(), error);
        Assert.Contains(target, error);
        Assert.Equal(JsonValueKind.Null, result.GetProperty("rowVersion").ValueKind);
        var after = await SnapshotAsync(created.Id);
        Assert.Equal(before, after, SnapshotComparer.Instance);
        Assert.Empty(after.History);
    }

    // ---------------------------------------------------------------- Partial Success

    [Fact]
    public async Task MixedBatch_ReturnsTheRightOutcomeForEachItem_AndOnlyTheValidRowsChange()
    {
        // Target status: InProgress. Sent in this order: valid, missing, stale, disallowed, valid.
        var valid1 = await CreateRequestAsync(RequestStatus.New);
        var stale = await CreateRequestAsync(RequestStatus.New);
        var disallowed = await CreateRequestAsync(RequestStatus.Completed);
        var valid2 = await CreateRequestAsync(RequestStatus.Waiting);
        await BulkAsync("Waiting", [stale]); // makes the version held by the client stale
        var before = new Dictionary<int, Snapshot>();
        foreach (var id in new[] { valid1.Id, stale.Id, disallowed.Id, valid2.Id })
        {
            before[id] = await SnapshotAsync(id);
        }

        var missing = (int.MaxValue - 1, Convert.ToBase64String(new byte[8]));
        var body = await BulkAsync("InProgress", [valid1, missing, stale, disallowed, valid2], changedBy: "mixed");

        Assert.Equal((5, 2, 3), Counts(body));
        var results = body.GetProperty("results").EnumerateArray().ToArray();
        Assert.Equal(
            [valid1.Id, missing.Item1, stale.Id, disallowed.Id, valid2.Id],
            results.Select(r => r.GetProperty("id").GetInt32()));
        Assert.Equal(
            ["Updated", "NotFound", "Conflict", "InvalidTransition", "Updated"],
            results.Select(r => r.GetProperty("outcome").GetString()));

        // Valid rows changed, each with exactly one new history row and the version we were told about.
        foreach (var (item, result) in new[] { (valid1, results[0]), (valid2, results[4]) })
        {
            var after = await SnapshotAsync(item.Id);
            Assert.Equal(RequestStatus.InProgress, after.Status);
            Assert.Equal(after.RowVersion, result.GetProperty("rowVersion").GetString());
            var entry = Assert.Single(after.History);
            Assert.Equal((before[item.Id].Status, RequestStatus.InProgress, "mixed"), (entry.PreviousStatus, entry.NewStatus, entry.ChangedBy));
        }

        // Failed rows are untouched: no status, UpdatedAt, RowVersion or history change.
        foreach (var id in new[] { stale.Id, disallowed.Id })
        {
            Assert.Equal(before[id], await SnapshotAsync(id), SnapshotComparer.Instance);
        }

        // History rows = successes (the stale row keeps only the one row from the earlier call).
        await using var db = CreateContext(_connectionString);
        var ids = new[] { valid1.Id, stale.Id, disallowed.Id, valid2.Id, missing.Item1 };
        Assert.Equal(2, await db.RequestStatusHistory.CountAsync(h => ids.Contains(h.RequestId) && h.ChangedBy == "mixed"));
        Assert.Equal(1, await db.RequestStatusHistory.CountAsync(h => h.RequestId == stale.Id));
    }

    [Fact]
    public async Task CommitBetweenLoadAndSave_ConflictsOnlyThatItem_TheOthersStayCommitted_AndItsHistoryIsRolledBack()
    {
        // Forced race: another connection commits just before the first item is saved. The early version comparison
        // has already passed, so only the rowversion in the WHERE clause of the UPDATE can detect the lost update.
        var raced = await CreateRequestAsync(RequestStatus.New);
        var other1 = await CreateRequestAsync(RequestStatus.New);
        var other2 = await CreateRequestAsync(RequestStatus.Waiting);
        var competing = new CompetingCommitInterceptor(_connectionString, raced.Id, RequestStatus.Waiting);
        var log = new CommandLog();
        await using var db = CreateContext(_connectionString, competing, log);
        var service = CreateService(db);

        var result = await service.BulkUpdateStatusAsync(
            RequestStatus.InProgress,
            [new(raced.Id, Convert.FromBase64String(raced.RowVersion)), new(other1.Id, Convert.FromBase64String(other1.RowVersion)), new(other2.Id, Convert.FromBase64String(other2.RowVersion))],
            "bulk-user",
            CancellationToken.None);

        Assert.True(competing.Fired);
        Assert.Equal((3, 2, 1), (result.Requested, result.Succeeded, result.Failed));
        Assert.Equal(
            [StatusUpdateOutcome.Conflict, StatusUpdateOutcome.Updated, StatusUpdateOutcome.Updated],
            result.Results.Select(r => r.Outcome));

        var racedAfter = await SnapshotAsync(raced.Id);
        Assert.Equal(RequestStatus.Waiting, racedAfter.Status); // the competing commit survived
        Assert.Equal(racedAfter.RowVersion, result.Results[0].RowVersion); // the conflict reports what is current now
        Assert.Empty(racedAfter.History); // the history INSERT was sent before the failing UPDATE; it was rolled back
        var sql = string.Join("\n", log.Commands);
        Assert.True(
            sql.IndexOf("INSERT INTO [RequestStatusHistory]", StringComparison.Ordinal) is var insertAt
            && insertAt >= 0 && sql.IndexOf("UPDATE [Requests]", StringComparison.Ordinal) > insertAt,
            sql);

        foreach (var item in new[] { other1, other2 })
        {
            var after = await SnapshotAsync(item.Id);
            Assert.Equal(RequestStatus.InProgress, after.Status);
            Assert.Equal("bulk-user", Assert.Single(after.History).ChangedBy);
        }
    }

    [Fact]
    public async Task TwoParallelBatchesOverTheSameRows_UpdateEachRowExactlyOnce()
    {
        var rows = await CreateRequestsAsync(RequestStatus.New, 20);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        async Task<JsonElement> SendAsync(string status, string user)
        {
            await gate.Task; // synchronised start
            return await BulkAsync(status, rows, user);
        }

        var first = Task.Run(() => SendAsync("InProgress", "user-a"));
        var second = Task.Run(() => SendAsync("Waiting", "user-b"));
        gate.SetResult();
        var bodies = await Task.WhenAll(first, second);

        // Every row has exactly one winner, whichever batch got there first.
        Assert.Equal(20, bodies.Sum(b => b.GetProperty("succeeded").GetInt32()));
        Assert.Equal(20, bodies.Sum(b => b.GetProperty("failed").GetInt32()));
        Assert.All(bodies.SelectMany(b => b.GetProperty("results").EnumerateArray()),
            r => Assert.Contains(r.GetProperty("outcome").GetString(), new[] { "Updated", "Conflict" }));
        foreach (var row in rows)
        {
            var after = await SnapshotAsync(row.Id);
            var entry = Assert.Single(after.History);
            Assert.Equal(after.Status, entry.NewStatus);
        }
    }

    // ---------------------------------------------------------------- limits: 100 / 101 items

    [Fact]
    public async Task OneHundredItems_AreAccepted_AndAllUpdated()
    {
        var rows = await CreateRequestsAsync(RequestStatus.New, 100);

        var body = await BulkAsync("InProgress", rows);

        Assert.Equal((100, 100, 0), Counts(body));
        await using var db = CreateContext(_connectionString);
        var ids = rows.Select(r => r.Id).ToArray();
        Assert.Equal(100, await db.Requests.CountAsync(r => ids.Contains(r.Id) && r.Status == RequestStatus.InProgress));
        Assert.Equal(100, await db.RequestStatusHistory.CountAsync(h => ids.Contains(h.RequestId)));
    }

    [Fact]
    public async Task OneHundredAndOneItems_Returns400_AndChangesNothing()
    {
        var rows = await CreateRequestsAsync(RequestStatus.New, 101);

        using var response = await PostAsync("InProgress", rows);

        var problem = await AssertProblemAsync(response, HttpStatusCode.BadRequest);
        Assert.Contains(problem.GetProperty("errors").EnumerateObject(), e => e.Name == "items");
        await AssertUntouchedAsync(rows);
    }

    // ---------------------------------------------------------------- invalid input

    [Theory]
    [InlineData("""{"status":"InProgress","items":[]}""", "items")]
    [InlineData("""{"status":"InProgress"}""", "items")]
    [InlineData("""{"status":"InProgress","items":null}""", "items")]
    [InlineData("""{"status":"Bogus","items":[{"id":{ID},"rowVersion":"{V}"}]}""", "status")]
    [InlineData("""{"status":7,"items":[{"id":{ID},"rowVersion":"{V}"}]}""", "status")]
    [InlineData("""{"status":0,"items":[{"id":{ID},"rowVersion":"{V}"}]}""", "status")]
    [InlineData("""{"status":null,"items":[{"id":{ID},"rowVersion":"{V}"}]}""", "status")]
    [InlineData("""{"items":[{"id":{ID},"rowVersion":"{V}"}]}""", "status")]
    [InlineData("""{"status":"InProgress","items":[{"id":{ID},"rowVersion":"{V}"},{"id":{ID},"rowVersion":"{V}"}]}""", "items")]
    [InlineData("""{"status":"InProgress","items":[{"id":{ID},"rowVersion":"{V}"},null]}""", "items[1]")]
    [InlineData("""{"status":"InProgress","items":[{"id":{ID},"rowVersion":"{V}"},{"rowVersion":"{V}"}]}""", "items[1].id")]
    [InlineData("""{"status":"InProgress","items":[{"id":{ID},"rowVersion":"{V}"},{"id":99}]}""", "items[1].rowVersion")]
    [InlineData("""{"status":"InProgress","items":[{"id":{ID},"rowVersion":"{V}"},{"id":99,"rowVersion":""}]}""", "items[1].rowVersion")]
    [InlineData("""{"status":"InProgress","items":[{"id":{ID},"rowVersion":"{V}"},{"id":99,"rowVersion":"not base64!"}]}""", "items[1].rowVersion")]
    [InlineData("""{"status":"InProgress","items":[{"id":"abc","rowVersion":"{V}"}]}""", "items[0].id")]
    public async Task InvalidBody_Returns400ProblemDetails_WithAnErrorForTheField_AndChangesNothing(string json, string field)
    {
        // The first item is always a real, valid row: a bad item elsewhere must stop the whole call.
        var created = await CreateRequestAsync(RequestStatus.New);

        using var response = await SendRawAsync(
            json.Replace("{ID}", created.Id.ToString(), StringComparison.Ordinal).Replace("{V}", created.RowVersion, StringComparison.Ordinal));

        var problem = await AssertProblemAsync(response, HttpStatusCode.BadRequest);
        Assert.Contains(problem.GetProperty("errors").EnumerateObject(),
            e => e.Name.Contains(field, StringComparison.OrdinalIgnoreCase));
        await AssertUntouchedAsync([created]);
    }

    [Theory]
    [InlineData("")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{not json")]
    public async Task EmptyOrMalformedBody_Returns400ProblemDetails(string json)
    {
        using var response = await SendRawAsync(json);

        await AssertProblemAsync(response, HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task TooLongUserName_Returns400_AndChangesNothing()
    {
        var created = await CreateRequestAsync(RequestStatus.New);

        using var response = await PostAsync("InProgress", [created], changedBy: new string('n', 101));

        var problem = await AssertProblemAsync(response, HttpStatusCode.BadRequest);
        Assert.Contains(problem.GetProperty("errors").EnumerateObject(), e => e.Name == "X-User-Name");
        await AssertUntouchedAsync([created]);
    }

    // ---------------------------------------------------------------- helpers

    private static async Task MigrateAsync(string connectionString)
    {
        await using var db = CreateContext(connectionString);
        await db.Database.MigrateAsync();
    }

    private static AppDbContext CreateContext(string connectionString, params IInterceptor[] interceptors) =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connectionString).AddInterceptors(interceptors).Options);

    private static RequestStatusService CreateService(AppDbContext db) =>
        new(db, new StatusTransitionPolicy(), TimeProvider.System, NullLogger<RequestStatusService>.Instance);

    private static DateTime TruncateToMilliseconds(DateTime value) =>
        new(value.Ticks - value.Ticks % TimeSpan.TicksPerMillisecond, DateTimeKind.Utc);

    private static (int, int, int) Counts(JsonElement body) =>
        (body.GetProperty("requested").GetInt32(), body.GetProperty("succeeded").GetInt32(), body.GetProperty("failed").GetInt32());

    private async Task<(int Id, string RowVersion)> CreateRequestAsync(RequestStatus status) =>
        Assert.Single(await CreateRequestsAsync(status, 1));

    private async Task<List<(int Id, string RowVersion)>> CreateRequestsAsync(RequestStatus status, int count)
    {
        var created = TruncateToMilliseconds(DateTime.UtcNow.AddDays(-1));
        await using var db = CreateContext(_connectionString);
        var requests = Enumerable.Range(0, count).Select(_ => new Request
        {
            Title = $"Bulk test {Guid.NewGuid():N}",
            OrganizationName = "Bulk Test Ltd",
            Status = status,
            Priority = RequestPriority.Medium,
            CreatedAt = created,
            UpdatedAt = created,
        }).ToList();
        db.Requests.AddRange(requests);
        await db.SaveChangesAsync();
        return requests.Select(r => (r.Id, Convert.ToBase64String(r.Version))).ToList();
    }

    private async Task<Snapshot> SnapshotAsync(int id)
    {
        await using var db = CreateContext(_connectionString);
        var request = await db.Requests.AsNoTracking().SingleAsync(r => r.Id == id);
        var history = await db.RequestStatusHistory.AsNoTracking().Where(h => h.RequestId == id).OrderBy(h => h.Id).ToListAsync();
        return new Snapshot(request.Status, request.UpdatedAt, Convert.ToBase64String(request.Version), history);
    }

    /// <summary>Rows created as <see cref="RequestStatus.New"/> and never changed: same version, no history.</summary>
    private async Task AssertUntouchedAsync(IEnumerable<(int Id, string RowVersion)> rows)
    {
        foreach (var row in rows)
        {
            var snapshot = await SnapshotAsync(row.Id);
            Assert.Equal(RequestStatus.New, snapshot.Status);
            Assert.Equal(row.RowVersion, snapshot.RowVersion);
            Assert.Empty(snapshot.History);
        }
    }

    private Task<HttpResponseMessage> PostAsync(string status, IEnumerable<(int Id, string RowVersion)> items, string? changedBy = null)
    {
        var message = new HttpRequestMessage(HttpMethod.Post, "/api/requests/bulk-status")
        {
            Content = JsonContent.Create(new { status, items = items.Select(i => new { id = i.Id, rowVersion = i.RowVersion }) }),
        };
        if (changedBy is not null)
        {
            message.Headers.Add(ChangedBy.HeaderName, changedBy);
        }

        return _client.SendAsync(message);
    }

    private async Task<JsonElement> BulkAsync(string status, IEnumerable<(int Id, string RowVersion)> items, string? changedBy = null)
    {
        using var response = await PostAsync(status, items, changedBy);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }

    private Task<HttpResponseMessage> SendRawAsync(string json) =>
        _client.SendAsync(new HttpRequestMessage(HttpMethod.Post, "/api/requests/bulk-status")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        });

    private static async Task<JsonElement> AssertProblemAsync(HttpResponseMessage response, HttpStatusCode expected)
    {
        Assert.Equal(expected, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal((int)expected, problem.GetProperty("status").GetInt32());
        return problem;
    }

    private sealed record Snapshot(RequestStatus Status, DateTime UpdatedAt, string RowVersion, List<RequestStatusHistoryEntry> History);

    private sealed class SnapshotComparer : IEqualityComparer<Snapshot>
    {
        public static readonly SnapshotComparer Instance = new();

        public bool Equals(Snapshot? x, Snapshot? y) =>
            x is not null && y is not null
            && x.Status == y.Status && x.UpdatedAt == y.UpdatedAt && x.RowVersion == y.RowVersion
            && x.History.Select(h => h.Id).SequenceEqual(y.History.Select(h => h.Id));

        public int GetHashCode(Snapshot obj) => HashCode.Combine(obj.Status, obj.UpdatedAt, obj.RowVersion);
    }

    /// <summary>Commits a competing change on a separate connection just before the first SaveChanges runs.</summary>
    private sealed class CompetingCommitInterceptor(string connectionString, int id, RequestStatus status) : SaveChangesInterceptor
    {
        public bool Fired { get; private set; }

        public override async ValueTask<InterceptionResult<int>> SavingChangesAsync(
            DbContextEventData eventData, InterceptionResult<int> result, CancellationToken cancellationToken = default)
        {
            if (!Fired)
            {
                Fired = true;
                await using var connection = new SqlConnection(connectionString);
                await connection.OpenAsync(cancellationToken);
                await using var command = new SqlCommand("UPDATE [Requests] SET [Status] = @status WHERE [Id] = @id", connection);
                command.Parameters.AddWithValue("@status", (byte)status);
                command.Parameters.AddWithValue("@id", id);
                await command.ExecuteNonQueryAsync(cancellationToken);
            }

            return result;
        }
    }

    /// <summary>Records the SQL text of every command EF Core sends, in order.</summary>
    private sealed class CommandLog : Microsoft.EntityFrameworkCore.Diagnostics.DbCommandInterceptor
    {
        public List<string> Commands { get; } = [];

        public override ValueTask<InterceptionResult<System.Data.Common.DbDataReader>> ReaderExecutingAsync(
            System.Data.Common.DbCommand command, CommandEventData eventData, InterceptionResult<System.Data.Common.DbDataReader> result, CancellationToken cancellationToken = default)
        {
            Commands.Add(command.CommandText);
            return ValueTask.FromResult(result);
        }
    }
}
