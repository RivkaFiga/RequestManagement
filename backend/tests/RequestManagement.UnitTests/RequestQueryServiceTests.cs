using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.UnitTests;

/// <summary>
/// Captures the SQL that EF Core generates (T-202 verification, R1.1, R6.5). No database connection is opened:
/// <c>ToQueryString()</c> only translates the query.
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
