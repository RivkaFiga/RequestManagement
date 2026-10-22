using System.Data.Common;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// T-208 / IT-7 (R7.1-R7.3, R1.6). The API runs in-process against a real SQL Server database with an EF Core
/// interceptor that counts every command, so "a cache hit sends no SQL" is measured, not assumed. Each test has its own
/// database with a known distribution and compares against independent, hand-written GROUP BY SQL. Tests that need
/// time use a manual clock that replaces the host's <see cref="TimeProvider"/>.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class RequestSummaryCacheApiTests(SqlServerFixture sqlServer)
{
    private static readonly DateTime Created = new(2026, 9, 1, 8, 0, 0, DateTimeKind.Utc);

    // (status, rows): 12 rows in total.
    private static readonly (RequestStatus Status, int Rows)[] Distribution =
    [
        (RequestStatus.New, 6),
        (RequestStatus.InProgress, 3),
        (RequestStatus.Waiting, 2),
        (RequestStatus.Completed, 1),
    ];

    // ---------------------------------------------------------------- R7.1: a hit sends no SQL

    [Fact]
    public async Task RepeatedSummary_IsServedFromTheCache_WithoutSendingAnySql()
    {
        await using var env = await StartAsync();

        var first = await env.GetSummaryTextAsync();
        var afterFirst = env.Commands.Count;
        var second = await env.GetSummaryTextAsync();
        var third = await env.GetSummaryTextAsync();

        Assert.Equal(2, afterFirst); // the miss: the two GROUP BY queries
        Assert.Equal(afterFirst, env.Commands.Count); // the hits: no command at all
        Assert.Equal(first, second);
        Assert.Equal(first, third); // including generatedAt, because it is the same cached value
    }

    // ---------------------------------------------------------------- R7.3 / IT-7: fresh right after an update

    [Fact]
    public async Task AfterAPatch_TheVeryNextSummaryShowsTheChange_AndMatchesSql()
    {
        await using var env = await StartAsync();
        var before = await env.GetSummaryAsync();
        var row = env.Rows.First(r => r.Status == RequestStatus.New);

        using var patch = await env.PatchAsync(row.Id, "InProgress", row.RowVersion);
        Assert.Equal(HttpStatusCode.OK, patch.StatusCode);
        var commandsBefore = env.Commands.Count;
        var after = await env.GetSummaryAsync();

        Assert.Equal(before.Total, after.Total);
        Assert.Equal(before.Status(RequestStatus.New) - 1, after.Status(RequestStatus.New));
        Assert.Equal(before.Status(RequestStatus.InProgress) + 1, after.Status(RequestStatus.InProgress));
        Assert.Equal(2, env.Commands.Count - commandsBefore); // it was recomputed, not served stale
        await AssertMatchesSqlAsync(env, after);
    }

    [Fact]
    public async Task AfterABulkUpdate_TheVeryNextSummaryShowsExactlyTheSucceededItems()
    {
        await using var env = await StartAsync();
        var before = await env.GetSummaryAsync();
        var news = env.Rows.Where(r => r.Status == RequestStatus.New).Take(3).ToList();
        var completed = env.Rows.First(r => r.Status == RequestStatus.Completed);
        var items = news.Append(completed).Select(r => (r.Id, r.RowVersion)).Append((int.MaxValue, Convert.ToBase64String(new byte[8]))).ToList();

        using var bulk = await env.BulkAsync("InProgress", items);
        var body = await bulk.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(3, body.GetProperty("succeeded").GetInt32()); // 3 valid, 1 disallowed, 1 missing
        var after = await env.GetSummaryAsync();

        Assert.Equal(before.Total, after.Total);
        Assert.Equal(before.Status(RequestStatus.New) - 3, after.Status(RequestStatus.New));
        Assert.Equal(before.Status(RequestStatus.InProgress) + 3, after.Status(RequestStatus.InProgress));
        Assert.Equal(before.Status(RequestStatus.Completed), after.Status(RequestStatus.Completed));
        await AssertMatchesSqlAsync(env, after);
    }

    [Fact]
    public async Task UpdatesThatChangeNothing_DoNotInvalidate_SoTheNextSummaryIsStillAHit()
    {
        await using var env = await StartAsync();
        var warm = await env.GetSummaryTextAsync();
        var news = env.Rows.Where(r => r.Status == RequestStatus.New).Take(2).ToList();
        var completed = env.Rows.First(r => r.Status == RequestStatus.Completed);
        var commandsBefore = env.Commands.Count;

        using var disallowed = await env.PatchAsync(completed.Id, "InProgress", completed.RowVersion); // 422
        using var stale = await env.PatchAsync(news[0].Id, "InProgress", Convert.ToBase64String(new byte[8])); // 409
        using var missing = await env.PatchAsync(int.MaxValue, "InProgress", news[0].RowVersion); // 404
        using var bulk = await env.BulkAsync("InProgress", [completed, (int.MaxValue, news[0].RowVersion), (news[1].Id, Convert.ToBase64String(new byte[8]))]);

        Assert.Equal(
            new[] { HttpStatusCode.UnprocessableEntity, HttpStatusCode.Conflict, HttpStatusCode.NotFound, HttpStatusCode.OK },
            new[] { disallowed.StatusCode, stale.StatusCode, missing.StatusCode, bulk.StatusCode });
        Assert.Equal(0, (await bulk.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("succeeded").GetInt32());
        var commandsAfterWrites = env.Commands.Count;
        var again = await env.GetSummaryTextAsync();

        Assert.True(commandsAfterWrites > commandsBefore); // the writes did talk to the database...
        Assert.Equal(commandsAfterWrites, env.Commands.Count); // ...but the summary read did not
        Assert.Equal(warm, again);
    }

    // ---------------------------------------------------------------- R7.2: expiry

    [Fact]
    public async Task TheSummaryExpiresAfterTheConfiguredSeconds_AndThenReflectsTheDatabase()
    {
        await using var env = await StartAsync(new Dictionary<string, string?> { ["SummaryCache:ExpirationSeconds"] = "30" });
        var before = await env.GetSummaryAsync();
        await env.ExecuteSqlAsync("UPDATE [Requests] SET [Status] = 3 WHERE [Id] = " + env.Rows.First(r => r.Status == RequestStatus.New).Id); // behind the API's back

        env.Clock.Advance(TimeSpan.FromSeconds(29));
        var stillCached = await env.GetSummaryAsync();
        env.Clock.Advance(TimeSpan.FromSeconds(1));
        var commandsBefore = env.Commands.Count;
        var refreshed = await env.GetSummaryAsync();

        Assert.Equal(before.Status(RequestStatus.New), stillCached.Status(RequestStatus.New));
        Assert.Equal(before.Status(RequestStatus.New) - 1, refreshed.Status(RequestStatus.New));
        Assert.Equal(before.Status(RequestStatus.Waiting) + 1, refreshed.Status(RequestStatus.Waiting));
        Assert.Equal(2, env.Commands.Count - commandsBefore);
    }

    [Fact]
    public async Task WithTheCacheDisabled_EveryRequestReadsTheDatabase()
    {
        await using var env = await StartAsync(new Dictionary<string, string?> { ["SummaryCache:Enabled"] = "false" });

        await env.GetSummaryAsync();
        await env.GetSummaryAsync();
        await env.ExecuteSqlAsync("UPDATE [Requests] SET [Status] = 3 WHERE [Id] = " + env.Rows.First(r => r.Status == RequestStatus.New).Id);
        var after = await env.GetSummaryAsync();

        Assert.Equal(6, env.Commands.Count); // two queries per request, three requests
        Assert.Equal(5, after.Status(RequestStatus.New));
    }

    [Fact]
    public async Task ANonPositiveExpiration_IsRejectedAtStartup()
    {
        var connectionString = sqlServer.CreateIsolatedConnectionString("SummaryCacheConfig");
        using var factory = new ApiFactory(connectionString, new Dictionary<string, string?> { ["SummaryCache:ExpirationSeconds"] = "0" });

        var error = await Record.ExceptionAsync(() => Task.Run(() => factory.CreateClient()));

        Assert.NotNull(error);
        Assert.Contains("ExpirationSeconds", error.ToString());
    }

    // ---------------------------------------------------------------- races

    [Fact]
    public async Task AnUpdateCommittedWhileTheSummaryIsBeingComputed_IsNeverHiddenByTheStaleResult()
    {
        // Forced interleaving at the real database: the reader has read the status counts, and just before it reads
        // the priority counts a status update commits and invalidates the cache. The reader's value is now stale. A
        // cache that only removed its entry would store that value afterwards and serve it until it expires; the
        // generation guard must refuse to store it.
        var connectionString = await PrepareDatabaseAsync("SummaryRace");
        var cache = new RequestSummaryCache(Options.Create(new SummaryCacheOptions()), TimeProvider.System);
        var target = (await LoadRowsAsync(connectionString)).First(r => r.Status == RequestStatus.New);

        var race = new BeforeSecondQueryInterceptor(async () =>
        {
            await using var writerDb = CreateContext(connectionString);
            var writer = new RequestStatusService(
                writerDb, new StatusTransitionPolicy(), TimeProvider.System, cache, NullLogger<RequestStatusService>.Instance);
            var result = await writer.UpdateStatusAsync(
                target.Id, RequestStatus.InProgress, Convert.FromBase64String(target.RowVersion), "racer", CancellationToken.None);
            Assert.Equal(StatusUpdateOutcome.Updated, result.Outcome);
        });
        await using var readerDb = CreateContext(connectionString, race);
        var slowReader = new RequestQueryService(readerDb, new StatusTransitionPolicy(), TimeProvider.System, cache);

        var staleResult = await slowReader.GetSummaryAsync(CancellationToken.None);

        Assert.True(race.Fired);
        Assert.Equal(6, staleResult.ByStatus.Single(c => c.Status == RequestStatus.New).Count); // the race really happened

        await using var freshDb = CreateContext(connectionString);
        var fresh = await new RequestQueryService(freshDb, new StatusTransitionPolicy(), TimeProvider.System, cache)
            .GetSummaryAsync(CancellationToken.None);
        Assert.Equal(5, fresh.ByStatus.Single(c => c.Status == RequestStatus.New).Count);
        Assert.Equal(4, fresh.ByStatus.Single(c => c.Status == RequestStatus.InProgress).Count);
    }

    [Fact]
    public async Task ParallelReadsAndUpdates_LeaveTheCacheMatchingTheDatabase()
    {
        await using var env = await StartAsync();
        await env.GetSummaryAsync();
        var news = env.Rows.Where(r => r.Status == RequestStatus.New).ToList();
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var readers = Enumerable.Range(0, 24).Select(_ => Task.Run(async () =>
        {
            await gate.Task;
            for (var i = 0; i < 5; i++)
            {
                await env.GetSummaryAsync();
            }
        }));
        var writers = news.Select(row => Task.Run(async () =>
        {
            await gate.Task;
            using var response = await env.PatchAsync(row.Id, "InProgress", row.RowVersion);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        }));
        var all = Task.WhenAll(readers.Concat(writers));
        gate.SetResult();
        await all;

        // Everything has finished; whatever order things happened in, the next summary reflects every update.
        var final = await env.GetSummaryAsync();
        Assert.Equal(0, final.Status(RequestStatus.New));
        Assert.Equal(9, final.Status(RequestStatus.InProgress));
        await AssertMatchesSqlAsync(env, final);
    }

    // ---------------------------------------------------------------- helpers

    private static AppDbContext CreateContext(string connectionString, params IInterceptor[] interceptors) =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connectionString).AddInterceptors(interceptors).Options);

    private async Task<string> PrepareDatabaseAsync(string name)
    {
        var connectionString = sqlServer.CreateIsolatedConnectionString(name);
        await using var db = CreateContext(connectionString);
        await db.Database.MigrateAsync();

        var n = 0;
        foreach (var (status, rows) in Distribution)
        {
            for (var i = 0; i < rows; i++, n++)
            {
                db.Requests.Add(new Request
                {
                    Title = $"Cache test request {n}",
                    OrganizationName = "Cache Test Ltd",
                    Status = status,
                    Priority = (RequestPriority)(n % 3 + 1),
                    CreatedAt = Created,
                    UpdatedAt = Created,
                });
            }
        }

        await db.SaveChangesAsync();
        return connectionString;
    }

    private static async Task<List<Row>> LoadRowsAsync(string connectionString)
    {
        await using var db = CreateContext(connectionString);
        var rows = await db.Requests.AsNoTracking().OrderBy(r => r.Id).ToListAsync();
        return rows.ConvertAll(r => new Row(r.Id, Convert.ToBase64String(r.Version), r.Status));
    }

    private async Task<Env> StartAsync(IReadOnlyDictionary<string, string?>? settings = null)
    {
        var connectionString = await PrepareDatabaseAsync("SummaryCache");
        var commands = new CommandCounter();
        var clock = new ManualClock();
        var factory = new ApiFactory(connectionString, settings, services =>
        {
            services.ConfigureDbContext<AppDbContext>(options => options.AddInterceptors(commands));
            services.AddSingleton<TimeProvider>(clock);
        });
        return new Env(factory, factory.CreateClient(), commands, clock, connectionString, await LoadRowsAsync(connectionString));
    }

    /// <summary>The summary as the database sees it, from independent SQL.</summary>
    private static async Task AssertMatchesSqlAsync(Env env, Summary summary)
    {
        await using var connection = new SqlConnection(env.ConnectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand("SELECT [Status], COUNT(*) FROM [Requests] GROUP BY [Status]", connection);
        await using var reader = await command.ExecuteReaderAsync();
        var sql = new Dictionary<RequestStatus, int>();
        while (await reader.ReadAsync())
        {
            sql[(RequestStatus)reader.GetByte(0)] = reader.GetInt32(1);
        }

        foreach (var status in Enum.GetValues<RequestStatus>())
        {
            Assert.Equal(sql.GetValueOrDefault(status), summary.Status(status));
        }

        Assert.Equal(sql.Values.Sum(), summary.Total);
    }

    private sealed record Row(int Id, string RowVersion, RequestStatus Status)
    {
        public static implicit operator (int Id, string RowVersion)(Row row) => (row.Id, row.RowVersion);
    }

    private sealed record Summary(int Total, Dictionary<RequestStatus, int> ByStatus)
    {
        public int Status(RequestStatus status) => ByStatus[status];
    }

    private sealed class Env(
        ApiFactory factory, HttpClient client, CommandCounter commands, ManualClock clock, string connectionString, List<Row> rows) : IAsyncDisposable
    {
        public CommandCounter Commands { get; } = commands;

        public ManualClock Clock { get; } = clock;

        public string ConnectionString { get; } = connectionString;

        public List<Row> Rows { get; } = rows;

        public async Task<string> GetSummaryTextAsync()
        {
            using var response = await client.GetAsync("/api/requests/summary");
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            return await response.Content.ReadAsStringAsync();
        }

        public async Task<Summary> GetSummaryAsync()
        {
            var root = JsonDocument.Parse(await GetSummaryTextAsync()).RootElement;
            return new Summary(
                root.GetProperty("total").GetInt32(),
                root.GetProperty("byStatus").EnumerateArray().ToDictionary(
                    e => Enum.Parse<RequestStatus>(e.GetProperty("status").GetString()!),
                    e => e.GetProperty("count").GetInt32()));
        }

        public Task<HttpResponseMessage> PatchAsync(int id, string status, string rowVersion) =>
            client.SendAsync(new HttpRequestMessage(HttpMethod.Patch, $"/api/requests/{id}/status")
            {
                Content = JsonContent.Create(new { status, rowVersion }),
            });

        public Task<HttpResponseMessage> BulkAsync(string status, IEnumerable<(int Id, string RowVersion)> items) =>
            client.PostAsJsonAsync("/api/requests/bulk-status", new { status, items = items.Select(i => new { id = i.Id, rowVersion = i.RowVersion }) });

        public async Task ExecuteSqlAsync(string sql)
        {
            await using var connection = new SqlConnection(ConnectionString);
            await connection.OpenAsync();
            await using var command = new SqlCommand(sql, connection);
            await command.ExecuteNonQueryAsync();
        }

        public ValueTask DisposeAsync()
        {
            client.Dispose();
            factory.Dispose();
            return ValueTask.CompletedTask;
        }
    }

    /// <summary>A clock that only moves when told to (its UTC time stays real; only the monotonic timestamp is manual).</summary>
    private sealed class ManualClock : TimeProvider
    {
        private long _ticks;

        public override long TimestampFrequency => TimeSpan.TicksPerSecond;

        public override long GetTimestamp() => Interlocked.Read(ref _ticks);

        public void Advance(TimeSpan by) => Interlocked.Add(ref _ticks, by.Ticks);
    }

    /// <summary>Counts every command EF Core sends, of any kind.</summary>
    private sealed class CommandCounter : DbCommandInterceptor
    {
        private int _count;

        public int Count => Volatile.Read(ref _count);

        public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref _count);
            return ValueTask.FromResult(result);
        }

        public override ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<int> result, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref _count);
            return ValueTask.FromResult(result);
        }

        public override ValueTask<InterceptionResult<object>> ScalarExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<object> result, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref _count);
            return ValueTask.FromResult(result);
        }
    }

    /// <summary>Runs an action once, right before the second query of the context is sent.</summary>
    private sealed class BeforeSecondQueryInterceptor(Func<Task> action) : DbCommandInterceptor
    {
        private int _queries;

        public bool Fired { get; private set; }

        public override async ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            if (++_queries == 2 && !Fired)
            {
                Fired = true;
                await action();
            }

            return result;
        }
    }
}
