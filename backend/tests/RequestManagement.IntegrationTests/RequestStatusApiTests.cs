using System.Data.Common;
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
/// T-205 / IT-2 to IT-5 (R2.1-R2.5, R3.1, R8.2-R8.5, R10.6). The API runs in-process against a real SQL Server
/// database. Every test creates its own rows and asserts only on them, so the tests are independent of each
/// other. Expected values are read back from the database with plain EF Core queries, not from the API under test.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class RequestStatusApiTests(SqlServerFixture sqlServer) : IAsyncLifetime
{
    private const string DatabaseKey = "StatusUpdate";

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

    // ---------------------------------------------------------------- IT-2: success

    [Fact]
    public async Task Update_Returns200_WithNewVersion_AndExactlyOneCorrectHistoryRow()
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        var before = await SnapshotAsync(created.Id);
        var sentAfter = TruncateToMilliseconds(DateTime.UtcNow);

        using var response = await PatchAsync(created.Id, "InProgress", before.RowVersion, changedBy: "dana");
        var receivedBefore = DateTime.UtcNow;

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var after = await SnapshotAsync(created.Id);

        // Response: the new state, including the new row version and the next allowed statuses.
        Assert.Equal(created.Id, body.GetProperty("id").GetInt32());
        Assert.Equal("InProgress", body.GetProperty("status").GetString());
        Assert.Equal(after.RowVersion, body.GetProperty("rowVersion").GetString());
        Assert.NotEqual(before.RowVersion, body.GetProperty("rowVersion").GetString());
        Assert.Equal(new[] { "Waiting", "Completed" },
            body.GetProperty("allowedNextStatuses").EnumerateArray().Select(e => e.GetString()).ToArray());
        Assert.EndsWith("Z", body.GetProperty("updatedAt").GetString());
        Assert.Equal(after.UpdatedAt, body.GetProperty("updatedAt").GetDateTime().ToUniversalTime());

        // Database: status, UpdatedAt and RowVersion changed together.
        Assert.Equal(RequestStatus.InProgress, after.Status);
        Assert.NotEqual(before.RowVersion, after.RowVersion);
        Assert.True(after.UpdatedAt > before.UpdatedAt);
        Assert.InRange(after.UpdatedAt, sentAfter, receivedBefore);

        // Exactly one audit row, with all the required fields.
        var entry = Assert.Single(after.History);
        Assert.Equal(created.Id, entry.RequestId);
        Assert.Equal(RequestStatus.New, entry.PreviousStatus);
        Assert.Equal(RequestStatus.InProgress, entry.NewStatus);
        Assert.Equal("dana", entry.ChangedBy);
        Assert.Equal(after.UpdatedAt, entry.ChangedAt);
    }

    [Fact]
    public async Task Update_ChainedWithTheReturnedVersion_RecordsEveryStepInOrder()
    {
        var created = await CreateRequestAsync(RequestStatus.New);

        var first = await PatchOkAsync(created.Id, "Waiting", created.RowVersion);
        var second = await PatchOkAsync(created.Id, "InProgress", first.GetProperty("rowVersion").GetString()!);
        var third = await PatchOkAsync(created.Id, "Completed", second.GetProperty("rowVersion").GetString()!);

        Assert.Empty(third.GetProperty("allowedNextStatuses").EnumerateArray());
        var snapshot = await SnapshotAsync(created.Id);
        Assert.Equal(RequestStatus.Completed, snapshot.Status);
        Assert.Equal(
            new[] { (RequestStatus.New, RequestStatus.Waiting), (RequestStatus.Waiting, RequestStatus.InProgress), (RequestStatus.InProgress, RequestStatus.Completed) },
            snapshot.History.OrderBy(h => h.Id).Select(h => (h.PreviousStatus, h.NewStatus)).ToArray());
    }

    [Fact]
    public async Task Update_WithoutUserHeader_RecordsAnonymous()
    {
        var created = await CreateRequestAsync(RequestStatus.New);

        using var response = await PatchAsync(created.Id, "Waiting", created.RowVersion);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("anonymous", Assert.Single((await SnapshotAsync(created.Id)).History).ChangedBy);
    }

    [Fact]
    public async Task Update_WithTooLongUserName_Returns400_AndChangesNothing()
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        var before = await SnapshotAsync(created.Id);

        using var response = await PatchAsync(created.Id, "Waiting", created.RowVersion, changedBy: new string('n', 101));

        var problem = await AssertProblemAsync(response, HttpStatusCode.BadRequest);
        Assert.Contains(problem.GetProperty("errors").EnumerateObject(), e => e.Name == "X-User-Name");
        Assert.Equal(before, await SnapshotAsync(created.Id), SnapshotComparer.Instance);
    }

    // ---------------------------------------------------------------- IT-3: stale version

    [Fact]
    public async Task StaleRowVersion_Returns409WithTheCurrentState_AndNothingIsChanged()
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        await PatchOkAsync(created.Id, "InProgress", created.RowVersion); // someone else got there first
        var before = await SnapshotAsync(created.Id);

        using var response = await PatchAsync(created.Id, "Waiting", created.RowVersion, changedBy: "late-user");

        var problem = await AssertProblemAsync(response, HttpStatusCode.Conflict);
        Assert.Equal("InProgress", problem.GetProperty("currentStatus").GetString());
        Assert.Equal(before.RowVersion, problem.GetProperty("currentRowVersion").GetString());

        var after = await SnapshotAsync(created.Id);
        Assert.Equal(before, after, SnapshotComparer.Instance); // status, UpdatedAt, RowVersion and history unchanged
        Assert.Single(after.History);
        Assert.DoesNotContain(after.History, h => h.ChangedBy == "late-user");
    }

    // ---------------------------------------------------------------- IT-4: real parallel updates

    [Fact]
    public async Task TwoParallelUpdatesWithTheSameVersion_ExactlyOneSucceeds_AndOnlyTheWinnerIsRecorded()
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        async Task<HttpStatusCode> SendAsync(string status, string user)
        {
            await gate.Task; // synchronised start
            using var response = await PatchAsync(created.Id, status, created.RowVersion, user);
            return response.StatusCode;
        }

        var first = Task.Run(() => SendAsync("InProgress", "user-a"));
        var second = Task.Run(() => SendAsync("Waiting", "user-b"));
        gate.SetResult();
        var codes = await Task.WhenAll(first, second);

        Assert.Equal(1, codes.Count(c => c == HttpStatusCode.OK));
        Assert.Equal(1, codes.Count(c => c == HttpStatusCode.Conflict));

        var winnerStatus = codes[0] == HttpStatusCode.OK ? RequestStatus.InProgress : RequestStatus.Waiting;
        var winnerUser = codes[0] == HttpStatusCode.OK ? "user-a" : "user-b";
        var after = await SnapshotAsync(created.Id);
        Assert.Equal(winnerStatus, after.Status);
        var entry = Assert.Single(after.History);
        Assert.Equal(winnerStatus, entry.NewStatus);
        Assert.Equal(winnerUser, entry.ChangedBy);
    }

    [Fact]
    public async Task CommitBetweenLoadAndSave_IsDetectedByTheDatabase_AsAConflict_AndTheHistoryRowIsRolledBack()
    {
        // The in-process race window is tiny, so force it: another connection commits right before this
        // service saves. The early version comparison passes; only the rowversion in the WHERE clause of the
        // UPDATE can detect the lost update.
        var created = await CreateRequestAsync(RequestStatus.New);
        var competing = new CompetingCommitInterceptor(_connectionString, created.Id, RequestStatus.Waiting);
        var log = new CommandLog();
        await using var db = CreateContext(_connectionString, competing, log);
        var service = CreateService(db);

        var result = await service.UpdateStatusAsync(
            created.Id, RequestStatus.InProgress, Convert.FromBase64String(created.RowVersion), "loser", CancellationToken.None);

        Assert.True(competing.Fired);
        Assert.Equal(StatusUpdateOutcome.Conflict, result.Outcome);
        var after = await SnapshotAsync(created.Id);
        Assert.Equal(RequestStatus.Waiting, result.CurrentStatus);
        Assert.Equal(after.RowVersion, result.CurrentRowVersion);
        Assert.Equal(RequestStatus.Waiting, after.Status); // the competing commit survived; ours did not overwrite it
        Assert.NotEqual(created.RowVersion, after.RowVersion);

        // EF Core sent the history INSERT before the failing UPDATE; it must not have survived the failure.
        var sql = string.Join("\n", log.Commands);
        var insertAt = sql.IndexOf("INSERT INTO [RequestStatusHistory]", StringComparison.Ordinal);
        var updateAt = sql.IndexOf("UPDATE [Requests]", StringComparison.Ordinal);
        Assert.True(insertAt >= 0 && updateAt > insertAt, sql);
        Assert.Empty(after.History);
    }

    // ---------------------------------------------------------------- atomicity of update + history

    [Fact]
    public async Task WhenTheHistoryRowCannotBeSaved_TheRequestIsNotChanged()
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        var before = await SnapshotAsync(created.Id);
        await using var db = CreateContext(_connectionString);
        var service = CreateService(db);

        // 101 characters do not fit the nvarchar(100) ChangedBy column, so the history INSERT fails
        // (the API rejects such a header earlier, so this goes straight to the service).
        await Assert.ThrowsAnyAsync<DbUpdateException>(() => service.UpdateStatusAsync(
            created.Id, RequestStatus.InProgress, Convert.FromBase64String(created.RowVersion), new string('n', 101), CancellationToken.None));

        var after = await SnapshotAsync(created.Id);
        Assert.Equal(before, after, SnapshotComparer.Instance);
        Assert.Empty(after.History);
    }


    // ---------------------------------------------------------------- IT-5: 404, 422, 400

    [Fact]
    public async Task MissingRequest_Returns404ProblemDetails()
    {
        using var response = await PatchAsync(int.MaxValue, "InProgress", Convert.ToBase64String(new byte[8]));

        var problem = await AssertProblemAsync(response, HttpStatusCode.NotFound);
        Assert.Contains(int.MaxValue.ToString(), problem.GetProperty("detail").GetString());
    }

    [Theory]
    [InlineData(RequestStatus.Completed, "InProgress")] // Completed is terminal
    [InlineData(RequestStatus.Completed, "Completed")]
    [InlineData(RequestStatus.New, "New")] // same status is not a transition
    [InlineData(RequestStatus.New, "Completed")] // must go through InProgress or Waiting
    [InlineData(RequestStatus.InProgress, "New")]
    [InlineData(RequestStatus.Waiting, "New")]
    public async Task DisallowedTransition_Returns422_NamesTheTransition_AndChangesNothing(RequestStatus current, string target)
    {
        var created = await CreateRequestAsync(current);
        var before = await SnapshotAsync(created.Id);

        using var response = await PatchAsync(created.Id, target, created.RowVersion);

        var problem = await AssertProblemAsync(response, HttpStatusCode.UnprocessableEntity);
        var detail = problem.GetProperty("detail").GetString();
        Assert.Contains(current.ToString(), detail);
        Assert.Contains(target, detail);
        Assert.Equal(before, await SnapshotAsync(created.Id), SnapshotComparer.Instance);
        Assert.Empty((await SnapshotAsync(created.Id)).History);
    }

    [Theory]
    [InlineData("""{"status":"Bogus","rowVersion":"{V}"}""", "status")]
    [InlineData("""{"status":7,"rowVersion":"{V}"}""", "status")]
    [InlineData("""{"status":0,"rowVersion":"{V}"}""", "status")]
    [InlineData("""{"status":null,"rowVersion":"{V}"}""", "status")]
    [InlineData("""{"rowVersion":"{V}"}""", "status")]
    [InlineData("""{"status":"InProgress"}""", "rowVersion")]
    [InlineData("""{"status":"InProgress","rowVersion":""}""", "rowVersion")]
    [InlineData("""{"status":"InProgress","rowVersion":"not base64!"}""", "rowVersion")]
    public async Task InvalidBody_Returns400ProblemDetails_WithAnErrorForTheField_AndChangesNothing(string json, string field)
    {
        var created = await CreateRequestAsync(RequestStatus.New);
        var before = await SnapshotAsync(created.Id);

        using var response = await SendRawAsync(created.Id, json.Replace("{V}", created.RowVersion, StringComparison.Ordinal));

        var problem = await AssertProblemAsync(response, HttpStatusCode.BadRequest);
        Assert.Contains(problem.GetProperty("errors").EnumerateObject(),
            e => e.Name.Contains(field, StringComparison.OrdinalIgnoreCase));
        Assert.Equal(before, await SnapshotAsync(created.Id), SnapshotComparer.Instance);
    }

    [Fact]
    public async Task EmptyBody_Returns400ProblemDetails()
    {
        var created = await CreateRequestAsync(RequestStatus.New);

        using var response = await SendRawAsync(created.Id, string.Empty);

        await AssertProblemAsync(response, HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task NonNumericId_Returns404()
    {
        using var response = await SendRawAsync("abc", """{"status":"Waiting","rowVersion":"AAAAAAAAB9E="}""");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
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

    private async Task<(int Id, string RowVersion)> CreateRequestAsync(RequestStatus status)
    {
        var created = TruncateToMilliseconds(DateTime.UtcNow.AddDays(-1));
        await using var db = CreateContext(_connectionString);
        var request = new Request
        {
            Title = $"Status test {Guid.NewGuid():N}",
            OrganizationName = "Status Test Ltd",
            Status = status,
            Priority = RequestPriority.Medium,
            CreatedAt = created,
            UpdatedAt = created,
        };
        db.Requests.Add(request);
        await db.SaveChangesAsync();
        return (request.Id, Convert.ToBase64String(request.Version));
    }

    private async Task<Snapshot> SnapshotAsync(int id)
    {
        await using var db = CreateContext(_connectionString);
        var request = await db.Requests.AsNoTracking().SingleAsync(r => r.Id == id);
        var history = await db.RequestStatusHistory.AsNoTracking().Where(h => h.RequestId == id).OrderBy(h => h.Id).ToListAsync();
        return new Snapshot(request.Status, request.UpdatedAt, Convert.ToBase64String(request.Version), history);
    }

    private Task<HttpResponseMessage> PatchAsync(int id, string status, string rowVersion, string? changedBy = null)
    {
        var message = new HttpRequestMessage(HttpMethod.Patch, $"/api/requests/{id}/status")
        {
            Content = JsonContent.Create(new { status, rowVersion }),
        };
        if (changedBy is not null)
        {
            message.Headers.Add(ChangedBy.HeaderName, changedBy);
        }

        return _client.SendAsync(message);
    }

    private Task<HttpResponseMessage> SendRawAsync(object id, string json) =>
        _client.SendAsync(new HttpRequestMessage(HttpMethod.Patch, $"/api/requests/{id}/status")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        });

    private async Task<JsonElement> PatchOkAsync(int id, string status, string rowVersion)
    {
        using var response = await PatchAsync(id, status, rowVersion);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }

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
    private sealed class CommandLog : DbCommandInterceptor
    {
        public List<string> Commands { get; } = [];

        public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            Commands.Add(command.CommandText);
            return ValueTask.FromResult(result);
        }
    }
}
