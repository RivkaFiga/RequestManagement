using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Options;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.UnitTests;

/// <summary>
/// Captures the SQL that EF Core generates (T-202 verification, R1.1, R6.5). No database is reached:
/// <c>ToQueryString()</c> only translates the page query, and the count command is captured before it is executed.
/// </summary>
public class RequestQueryServiceTests
{
    private static AppDbContext CreateContext() =>
        new(new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer("Server=unused;Database=unused;Trusted_Connection=True;TrustServerCertificate=True")
            .Options);

    private static string CaptureSql(RequestSearchQuery query)
    {
        using var db = CreateContext();
        var filtered = RequestQueryService.ApplyFilters(db.Requests.AsNoTracking(), query);
        return RequestQueryService.ApplySort(filtered, query.SortField, query.SortDescending)
            .Skip((query.Page - 1) * query.PageSize)
            .Take(query.PageSize)
            .ToQueryString();
    }

    [Fact]
    public void FullQuery_IsTranslatedToWhereOrderByAndOffsetFetch()
    {
        var sql = CaptureSql(new RequestSearchQuery
        {
            Page = 3,
            PageSize = 25,
            Search = "tax",
            Status = [RequestStatus.New, RequestStatus.Waiting],
            Priority = [RequestPriority.High],
            OrganizationName = "Acme",
            AssignedTo = "dana",
            CreatedFrom = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
            CreatedTo = new DateTimeOffset(2026, 6, 1, 0, 0, 0, TimeSpan.Zero),
            SortBy = "title",
            SortDirection = "asc",
        });

        Assert.Contains("WHERE", sql);
        Assert.Contains("LIKE", sql);
        Assert.Contains("ESCAPE", sql);
        Assert.Contains("ORDER BY", sql);
        Assert.Contains("OFFSET", sql);
        Assert.Contains("FETCH NEXT", sql);
    }

    [Fact]
    public void DefaultSort_IsCreatedAtDescending_WithIdTieBreaker()
    {
        var sql = CaptureSql(new RequestSearchQuery());

        var orderBy = sql[sql.IndexOf("ORDER BY", StringComparison.Ordinal)..];
        Assert.True(
            orderBy.IndexOf("[CreatedAt] DESC", StringComparison.Ordinal) < orderBy.IndexOf("[Id] DESC", StringComparison.Ordinal),
            orderBy);
    }

    [Fact]
    public void AscendingSort_UsesAscendingIdTieBreaker()
    {
        var sql = CaptureSql(new RequestSearchQuery { SortBy = "priority", SortDirection = "asc" });

        var orderBy = sql[sql.IndexOf("ORDER BY", StringComparison.Ordinal)..];
        Assert.Contains("[Priority]", orderBy);
        Assert.DoesNotContain("DESC", orderBy);
    }

    [Fact]
    public void NoFilters_ProducesNoWhereClause() =>
        Assert.DoesNotContain("WHERE", CaptureSql(new RequestSearchQuery()));

    [Fact]
    public async Task CountQuery_IsSelectCountOverTheSameWhereAsThePage()
    {
        var query = new RequestSearchQuery
        {
            Search = "tax",
            Status = [RequestStatus.New, RequestStatus.Waiting],
            Priority = [RequestPriority.High],
            OrganizationName = "Acme",
            AssignedTo = "dana",
            CreatedFrom = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
            CreatedTo = new DateTimeOffset(2026, 6, 1, 0, 0, 0, TimeSpan.Zero),
        };

        var countSql = await CaptureCountSqlAsync(query);

        Assert.StartsWith("SELECT COUNT(*)", countSql);
        Assert.DoesNotContain("ORDER BY", countSql);
        Assert.DoesNotContain("OFFSET", countSql);

        var pageSql = CaptureSql(query);
        Assert.Equal(WhereClause(pageSql), WhereClause(countSql));

        // Guard against a vacuous comparison: every filter of the query is really in the count's WHERE.
        foreach (var column in new[] { "[Title]", "[OrganizationName]", "[Status]", "[Priority]", "[AssignedTo]", "[CreatedAt]" })
        {
            Assert.Contains(column, WhereClause(countSql));
        }
    }

    /// <summary>
    /// Runs the real <see cref="RequestQueryService.SearchAsync"/> and records the first command EF is about to
    /// execute, which is the count. The interceptors suppress opening the connection and abort the execution, so no
    /// database is reached.
    /// </summary>
    private static async Task<string> CaptureCountSqlAsync(RequestSearchQuery query)
    {
        var commands = new CountCapture();
        await using var db = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer("Server=unused;Database=unused;Trusted_Connection=True;TrustServerCertificate=True")
            .AddInterceptors(commands, new SuppressConnectionOpen())
            .Options);
        var service = new RequestQueryService(
            db,
            new StatusTransitionPolicy(),
            TimeProvider.System,
            new RequestSummaryCache(Options.Create(new SummaryCacheOptions()), TimeProvider.System));

        await Assert.ThrowsAsync<CountCapture.Captured>(() => service.SearchAsync(query, CancellationToken.None));

        return commands.Text!;
    }

    private static string WhereClause(string sql)
    {
        var where = sql[sql.IndexOf("WHERE", StringComparison.Ordinal)..];
        var end = where.IndexOf("ORDER BY", StringComparison.Ordinal);
        return (end < 0 ? where : where[..end]).Trim();
    }

    private sealed class CountCapture : DbCommandInterceptor
    {
        public string? Text { get; private set; }

        public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            Text = command.CommandText;
            throw new Captured();
        }

        public sealed class Captured : Exception;
    }

    private sealed class SuppressConnectionOpen : DbConnectionInterceptor
    {
        public override ValueTask<InterceptionResult> ConnectionOpeningAsync(
            DbConnection connection, ConnectionEventData eventData, InterceptionResult result, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(InterceptionResult.Suppress());
    }

    [Theory]
    [InlineData("plain", "plain")]
    [InlineData("100%", "100\\%")]
    [InlineData("a_b", "a\\_b")]
    [InlineData("[x]", "\\[x]")]
    [InlineData("back\\slash", "back\\\\slash")]
    [InlineData("%_[\\", "\\%\\_\\[\\\\")]
    public void EscapeLike_EscapesWildcards(string input, string expected) =>
        Assert.Equal(expected, RequestQueryService.EscapeLike(input));
}
