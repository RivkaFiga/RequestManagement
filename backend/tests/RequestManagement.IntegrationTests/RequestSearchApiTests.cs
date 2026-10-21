using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using RequestManagement.Core.Domain;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Seeding;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// IT-1 (R1.2-R1.5, R1.7, R8.2, R8.5) and the get-by-id endpoint (T-203).
/// The API runs in-process against its own seeded, throw-away database. The expected results come from an
/// independent oracle: all rows are loaded and filtered/sorted/paged with LINQ-to-objects.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class RequestSearchApiTests(SqlServerFixture sqlServer) : IAsyncLifetime
{
    private const string DatabaseKey = "Search";
    private static readonly SeedOptions Seed = new() { Count = 2_500, BatchSize = 1_000 };

    private ApiFactory _factory = null!;
    private HttpClient _client = null!;
    private List<Request> _all = null!;

    public async Task InitializeAsync()
    {
        var connectionString = await sqlServer.GetSharedDatabaseAsync(DatabaseKey, SeedSearchDatabaseAsync);
        _factory = new ApiFactory(connectionString);
        _client = _factory.CreateClient();

        await using var db = CreateContext(connectionString);
        _all = await db.Requests.AsNoTracking().OrderBy(r => r.Id).ToListAsync();
    }

    public Task DisposeAsync()
    {
        _client.Dispose();
        _factory.Dispose();
        return Task.CompletedTask;
    }

    // ---------------------------------------------------------------- default, sorting, paging

    [Fact]
    public async Task Default_ReturnsTheNewestTwentyWithTheDocumentedShape()
    {
        using var response = await _client.GetAsync("/api/requests");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var root = await response.Content.ReadFromJsonAsync<JsonElement>();

        Assert.Equal(1, root.GetProperty("page").GetInt32());
        Assert.Equal(20, root.GetProperty("pageSize").GetInt32());
        Assert.Equal(_all.Count, root.GetProperty("totalCount").GetInt32());
        Assert.Equal((int)Math.Ceiling(_all.Count / 20.0), root.GetProperty("totalPages").GetInt32());
        Assert.Equal(Expected(_all).Take(20).ToArray(), Ids(root));

        var first = root.GetProperty("items")[0];
        var entity = _all.Single(r => r.Id == first.GetProperty("id").GetInt32());
        Assert.Equal(entity.Title, first.GetProperty("title").GetString());
        Assert.Equal(entity.OrganizationName, first.GetProperty("organizationName").GetString());
        Assert.Equal(entity.Status.ToString(), first.GetProperty("status").GetString());
        Assert.Equal(entity.Priority.ToString(), first.GetProperty("priority").GetString());
        Assert.Equal(entity.AssignedTo, first.GetProperty("assignedTo").GetString());
        Assert.EndsWith("Z", first.GetProperty("createdAt").GetString());
        Assert.EndsWith("Z", first.GetProperty("updatedAt").GetString());
        Assert.Equal(Convert.ToBase64String(entity.Version), first.GetProperty("rowVersion").GetString());
        Assert.Equal(
            new StatusTransitionPolicy().GetAllowedNextStatuses(entity.Status).Select(s => s.ToString()).ToArray(),
            first.GetProperty("allowedNextStatuses").EnumerateArray().Select(e => e.GetString()).ToArray());
    }

    [Theory]
    [InlineData("createdAt", "asc")]
    [InlineData("createdAt", "desc")]
    [InlineData("updatedAt", "asc")]
    [InlineData("updatedAt", "desc")]
    [InlineData("priority", "asc")]
    [InlineData("priority", "desc")]
    [InlineData("status", "asc")]
    [InlineData("status", "desc")]
    public async Task Sorting_MatchesTheOracle_WithIdAsTieBreaker(string sortBy, string direction)
    {
        var root = await GetOkAsync(Query(("sortBy", sortBy), ("sortDirection", direction), ("page", "2"), ("pageSize", "50")));

        var expected = Expected(_all, sortBy, direction == "desc").Skip(50).Take(50).ToArray();
        Assert.Equal(expected, Ids(root));
    }

    [Fact]
    public async Task TitleSort_AscendingIsExactlyTheReverseOfDescending_AndPagesDoNotOverlap()
    {
        var (descending, total) = await FetchAllAsync(Query(("sortBy", "title"), ("sortDirection", "desc")));
        var (ascending, _) = await FetchAllAsync(Query(("sortBy", "title"), ("sortDirection", "asc")));

        Assert.Equal(_all.Count, total);
        Assert.Equal(total, descending.Distinct().Count());
        Assert.Equal(descending.AsEnumerable().Reverse().ToArray(), ascending.ToArray());
    }

    [Fact]
    public async Task Paging_ReturnsExactSlices_AndTotalsAreConsistent()
    {
        var expected = Expected(_all);
        var lastPage = (int)Math.Ceiling(_all.Count / 100.0);

        var last = await GetOkAsync(Query(("page", lastPage.ToString(CultureInfo.InvariantCulture)), ("pageSize", "100")));
        Assert.Equal(expected.Skip((lastPage - 1) * 100).ToArray(), Ids(last));
        Assert.Equal(_all.Count, last.GetProperty("totalCount").GetInt32());
        Assert.Equal(lastPage, last.GetProperty("totalPages").GetInt32());

        var beyond = await GetOkAsync(Query(("page", (lastPage + 1).ToString(CultureInfo.InvariantCulture)), ("pageSize", "100")));
        Assert.Empty(Ids(beyond));
        Assert.Equal(_all.Count, beyond.GetProperty("totalCount").GetInt32());

        var huge = await GetOkAsync(Query(("page", int.MaxValue.ToString(CultureInfo.InvariantCulture)), ("pageSize", "100")));
        Assert.Empty(Ids(huge));

        var single = await GetOkAsync(Query(("page", "3"), ("pageSize", "1")));
        Assert.Equal(new[] { expected[2] }, Ids(single));
        Assert.Equal(_all.Count, single.GetProperty("totalPages").GetInt32());
    }

    // ---------------------------------------------------------------- filters and search

    [Fact]
    public async Task Filters_MatchTheOracle_Individually_AndCombined()
    {
        var row = _all.First(r => r.AssignedTo is not null && FirstWord(r.Title) is not null);
        var word = FirstWord(row.Title)!;
        var orgWord = FirstWord(_all[20].OrganizationName)!;
        var orgPrefix = row.OrganizationName[..Math.Min(6, row.OrganizationName.Length)];
        var windowFrom = _all.OrderBy(r => r.CreatedAt).ElementAt(500).CreatedAt;
        var windowTo = _all.OrderBy(r => r.CreatedAt).ElementAt(1500).CreatedAt;

        var scenarios = new (string Name, string Query, Func<Request, bool> Match)[]
        {
            ("status multi", Query(("status", "New"), ("status", "Waiting")),
                r => r.Status is RequestStatus.New or RequestStatus.Waiting),
            ("status numeric", Query(("status", "4")), r => r.Status == RequestStatus.Completed),
            ("priority", Query(("priority", "High")), r => r.Priority == RequestPriority.High),
            ("status and priority", Query(("status", "Completed"), ("priority", "Low")),
                r => r.Status == RequestStatus.Completed && r.Priority == RequestPriority.Low),
            ("organization prefix, case-insensitive", Query(("organizationName", orgPrefix.ToLowerInvariant())),
                r => r.OrganizationName.StartsWith(orgPrefix, StringComparison.OrdinalIgnoreCase)),
            ("assignedTo exact", Query(("assignedTo", row.AssignedTo!)),
                r => string.Equals(r.AssignedTo, row.AssignedTo, StringComparison.OrdinalIgnoreCase)),
            ("created window [from, to)", Query(("createdFrom", Iso(windowFrom)), ("createdTo", Iso(windowTo))),
                r => r.CreatedAt >= windowFrom && r.CreatedAt < windowTo),
            ("search in title", Query(("search", word.ToLowerInvariant())), r => ContainsText(r, word)),
            ("search in organization", Query(("search", orgWord.ToUpperInvariant())), r => ContainsText(r, orgWord)),
            ("all filters combined",
                Query(
                    ("search", word),
                    ("status", row.Status.ToString()),
                    ("priority", row.Priority.ToString()),
                    ("organizationName", orgPrefix),
                    ("assignedTo", row.AssignedTo!),
                    ("createdFrom", Iso(row.CreatedAt)),
                    ("createdTo", Iso(row.CreatedAt.AddMilliseconds(1)))),
                r => ContainsText(r, word)
                    && r.Status == row.Status
                    && r.Priority == row.Priority
                    && r.OrganizationName.StartsWith(orgPrefix, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(r.AssignedTo, row.AssignedTo, StringComparison.OrdinalIgnoreCase)
                    && r.CreatedAt >= row.CreatedAt
                    && r.CreatedAt < row.CreatedAt.AddMilliseconds(1)),
        };

        foreach (var (name, query, match) in scenarios)
        {
            var expected = Expected(_all.Where(match)).ToArray();
            Assert.True(expected.Length > 0, $"Scenario '{name}' must select at least one row to be meaningful.");

            var (actual, total) = await FetchAllAsync(query);

            Assert.True(expected.SequenceEqual(actual), $"Scenario '{name}': expected {expected.Length} rows, got {actual.Count}.");
            Assert.True(expected.Length == total, $"Scenario '{name}': totalCount {total} != {expected.Length}.");
        }
    }

    [Fact]
    public async Task CreatedRange_FromIsInclusive_ToIsExclusive()
    {
        var row = _all[7];

        var from = await GetOkAsync(Query(("createdFrom", Iso(row.CreatedAt)), ("createdTo", Iso(row.CreatedAt.AddMilliseconds(1)))));
        Assert.Contains(row.Id, Ids(from));

        var to = await GetOkAsync(Query(("createdFrom", Iso(row.CreatedAt.AddDays(-1))), ("createdTo", Iso(row.CreatedAt)), ("pageSize", "100")));
        Assert.DoesNotContain(row.Id, FetchedIds(to));
        Assert.All(_all.Where(r => Ids(to).Contains(r.Id)), r => Assert.True(r.CreatedAt < row.CreatedAt));
    }

    [Theory]
    [InlineData("100%")]
    [InlineData("a_b")]
    [InlineData("[ab]")]
    public async Task SearchWildcards_AreMatchedLiterally(string term)
    {
        var expected = Expected(_all.Where(r => ContainsText(r, term))).ToArray();
        Assert.NotEmpty(expected); // the seeded literal rows exist

        var (actual, total) = await FetchAllAsync(Query(("search", term)));

        Assert.Equal(expected, actual.ToArray());
        Assert.Equal(expected.Length, total);
        Assert.True(total < 10, "A wildcard leaked: far too many rows matched.");
    }

    [Fact]
    public async Task OrganizationNameWildcards_AreMatchedLiterally()
    {
        var root = await GetOkAsync(Query(("organizationName", "%")));

        Assert.Equal(0, root.GetProperty("totalCount").GetInt32());
    }

    // ---------------------------------------------------------------- validation

    [Theory]
    [InlineData("pageSize=500", "pageSize")]
    [InlineData("pageSize=101", "pageSize")]
    [InlineData("pageSize=0", "pageSize")]
    [InlineData("page=0", "page")]
    [InlineData("sortBy=bogus", "sortBy")]
    [InlineData("sortDirection=sideways", "sortDirection")]
    [InlineData("status=7", "status")]
    [InlineData("priority=0", "priority")]
    [InlineData("search=a", "search")]
    [InlineData("createdFrom=2026-05-02T00:00:00Z&createdTo=2026-05-01T00:00:00Z", "createdFrom")]
    public async Task InvalidParameters_Return400ProblemDetails_WithAnErrorForTheField(string query, string field)
    {
        using var response = await _client.GetAsync($"/api/requests?{query}");

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(400, problem.GetProperty("status").GetInt32());
        Assert.Contains(problem.GetProperty("errors").EnumerateObject(),
            e => string.Equals(e.Name, field, StringComparison.OrdinalIgnoreCase));
    }

    [Theory]
    [InlineData("status=Bogus")]
    [InlineData("priority=Urgent")]
    [InlineData("page=abc")]
    [InlineData("pageSize=ten")]
    [InlineData("createdFrom=not-a-date")]
    public async Task UnparsableParameters_Return400ProblemDetails(string query)
    {
        using var response = await _client.GetAsync($"/api/requests?{query}");

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task SeveralInvalidParameters_AreReportedTogether()
    {
        using var response = await _client.GetAsync("/api/requests?page=0&pageSize=500&sortBy=bogus");
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();

        var names = problem.GetProperty("errors").EnumerateObject().Select(e => e.Name.ToLowerInvariant()).ToArray();
        Assert.Contains("page", names);
        Assert.Contains("pagesize", names);
        Assert.Contains("sortby", names);
    }

    // ---------------------------------------------------------------- get by id (T-203)

    [Fact]
    public async Task GetById_ReturnsTheRequest()
    {
        var entity = _all[42];

        using var response = await _client.GetAsync($"/api/requests/{entity.Id}");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(entity.Id, body.GetProperty("id").GetInt32());
        Assert.Equal(entity.Title, body.GetProperty("title").GetString());
        Assert.Equal(entity.Status.ToString(), body.GetProperty("status").GetString());
        Assert.Equal(Convert.ToBase64String(entity.Version), body.GetProperty("rowVersion").GetString());
        Assert.Equal(
            new StatusTransitionPolicy().GetAllowedNextStatuses(entity.Status).Count,
            body.GetProperty("allowedNextStatuses").GetArrayLength());
    }

    [Theory]
    [InlineData("999999")]
    [InlineData("0")]
    [InlineData("-3")]
    public async Task GetById_UnknownId_Returns404ProblemDetails(string id)
    {
        using var response = await _client.GetAsync($"/api/requests/{id}");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(404, problem.GetProperty("status").GetInt32());
    }

    [Fact]
    public async Task GetById_NonNumericId_Returns404()
    {
        using var response = await _client.GetAsync("/api/requests/abc");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    // ---------------------------------------------------------------- isolation

    [Fact]
    public async Task TheApiUnderTest_UsesTheThrowAwayDatabase_NeverTheDevelopmentOne()
    {
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var catalog = new SqlConnectionStringBuilder(db.Database.GetConnectionString()).InitialCatalog;

        Assert.StartsWith($"RequestManagement_Tests_{DatabaseKey}_", catalog);
        Assert.Equal(_all.Count, await db.Requests.CountAsync());
    }

    // ---------------------------------------------------------------- seeding and helpers

    private static async Task SeedSearchDatabaseAsync(string connectionString)
    {
        await using (var db = CreateContext(connectionString))
        {
            var seeder = new DatabaseSeeder(db);
            await seeder.ResetDatabaseAsync(CancellationToken.None);
            await seeder.SeedAsync(Seed, null, CancellationToken.None);
        }

        // Rows with LIKE metacharacters, plus decoys that an unescaped wildcard would also match.
        var created = Seed.AnchorUtc.AddDays(-1);
        await using var extra = CreateContext(connectionString);
        extra.Requests.AddRange(
            Literal("Invoice 100% paid", created),
            Literal("Invoice 1000 items", created),
            Literal("Check a_b mapping", created),
            Literal("Check axb mapping", created),
            Literal("Tag [ab] selector", created));
        await extra.SaveChangesAsync();
    }

    private static Request Literal(string title, DateTime createdAt) => new()
    {
        Title = title,
        OrganizationName = "Literal Matching Ltd",
        Status = RequestStatus.New,
        Priority = RequestPriority.Low,
        CreatedAt = createdAt,
        UpdatedAt = createdAt,
    };

    private static AppDbContext CreateContext(string connectionString) =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connectionString).Options);

    private static string Query(params (string Key, string Value)[] pairs) =>
        string.Join("&", pairs.Select(p => $"{p.Key}={Uri.EscapeDataString(p.Value)}"));

    private static string Iso(DateTime utc) => utc.ToString("O", CultureInfo.InvariantCulture);

    private static string? FirstWord(string text) =>
        text.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(w => w.Length >= 3 && w.All(char.IsLetterOrDigit));

    private static bool ContainsText(Request r, string text) =>
        r.Title.Contains(text, StringComparison.OrdinalIgnoreCase)
        || r.OrganizationName.Contains(text, StringComparison.OrdinalIgnoreCase);

    private static int[] Expected(IEnumerable<Request> rows, string sortBy = "createdAt", bool descending = true)
    {
        Func<Request, long> key = sortBy switch
        {
            "updatedAt" => r => r.UpdatedAt.Ticks,
            "priority" => r => (long)r.Priority,
            "status" => r => (long)r.Status,
            _ => r => r.CreatedAt.Ticks,
        };

        return (descending
                ? rows.OrderByDescending(key).ThenByDescending(r => r.Id)
                : rows.OrderBy(key).ThenBy(r => r.Id))
            .Select(r => r.Id)
            .ToArray();
    }

    private static int[] Ids(JsonElement page) => FetchedIds(page);

    private static int[] FetchedIds(JsonElement page) =>
        page.GetProperty("items").EnumerateArray().Select(e => e.GetProperty("id").GetInt32()).ToArray();

    private async Task<JsonElement> GetOkAsync(string query)
    {
        using var response = await _client.GetAsync($"/api/requests?{query}");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }

    private async Task<(List<int> Ids, int TotalCount)> FetchAllAsync(string query)
    {
        var ids = new List<int>();
        var total = 0;
        for (var page = 1; ; page++)
        {
            var separator = query.Length > 0 ? "&" : string.Empty;
            var root = await GetOkAsync($"{query}{separator}page={page}&pageSize=100");
            total = root.GetProperty("totalCount").GetInt32();
            var pageIds = Ids(root);
            ids.AddRange(pageIds);
            if (pageIds.Length == 0 || ids.Count >= total)
            {
                return (ids, total);
            }
        }
    }
}
