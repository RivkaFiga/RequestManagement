using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.UnitTests;

/// <summary>T-204 (R1.6): the summary is built from two server-side GROUP BY queries. No database connection is opened.</summary>
public class RequestSummaryTests
{
    private static readonly DateTime Now = new(2026, 10, 21, 12, 0, 0, DateTimeKind.Utc);

    private static AppDbContext CreateContext() =>
        new(new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer("Server=unused;Database=unused;Trusted_Connection=True;TrustServerCertificate=True")
            .Options);

    [Fact]
    public void StatusCounts_AreGroupedAndCountedInSql()
    {
        using var db = CreateContext();

        var sql = RequestQueryService.CountByStatus(db.Requests.AsNoTracking()).ToQueryString();

        Assert.Contains("GROUP BY", sql);
        Assert.Contains("[Status]", sql[sql.IndexOf("GROUP BY", StringComparison.Ordinal)..]);
        Assert.Contains("COUNT(*)", sql);
        Assert.DoesNotContain("WHERE", sql);
        Assert.DoesNotContain("[Title]", sql);
    }

    [Fact]
    public void PriorityCounts_AreGroupedAndCountedInSql()
    {
        using var db = CreateContext();

        var sql = RequestQueryService.CountByPriority(db.Requests.AsNoTracking()).ToQueryString();

        Assert.Contains("GROUP BY", sql);
        Assert.Contains("[Priority]", sql[sql.IndexOf("GROUP BY", StringComparison.Ordinal)..]);
        Assert.Contains("COUNT(*)", sql);
        Assert.DoesNotContain("WHERE", sql);
        Assert.DoesNotContain("[Title]", sql);
    }

    [Fact]
    public void BuildSummary_ListsEveryDefinedValueInEnumOrder_AndTotalsTheCounts()
    {
        var summary = RequestQueryService.BuildSummary(
            [new(RequestStatus.Completed, 5), new(RequestStatus.New, 3)],
            [new(RequestPriority.High, 6), new(RequestPriority.Low, 2)],
            Now);

        Assert.Equal(8, summary.Total);
        Assert.Equal(Now, summary.GeneratedAt);
        Assert.Equal(
            new[] { (RequestStatus.New, 3), (RequestStatus.InProgress, 0), (RequestStatus.Waiting, 0), (RequestStatus.Completed, 5) },
            summary.ByStatus.Select(c => (c.Status, c.Count)).ToArray());
        Assert.Equal(
            new[] { (RequestPriority.Low, 2), (RequestPriority.Medium, 0), (RequestPriority.High, 6) },
            summary.ByPriority.Select(c => (c.Priority, c.Count)).ToArray());
        Assert.Equal(summary.Total, summary.ByStatus.Sum(c => c.Count));
        Assert.Equal(summary.Total, summary.ByPriority.Sum(c => c.Count));
    }

    [Fact]
    public void BuildSummary_WithNoRows_ReturnsZeroCountsForEveryValue()
    {
        var summary = RequestQueryService.BuildSummary([], [], Now);

        Assert.Equal(0, summary.Total);
        Assert.Equal(Enum.GetValues<RequestStatus>().Length, summary.ByStatus.Count);
        Assert.Equal(Enum.GetValues<RequestPriority>().Length, summary.ByPriority.Count);
        Assert.All(summary.ByStatus, c => Assert.Equal(0, c.Count));
        Assert.All(summary.ByPriority, c => Assert.Equal(0, c.Count));
    }
}
