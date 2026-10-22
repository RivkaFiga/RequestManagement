using Microsoft.EntityFrameworkCore;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.UnitTests;

/// <summary>
/// Captures the SQL of the history query (T-206, R3.2). No database connection is opened:
/// <c>ToQueryString()</c> only translates the query.
/// </summary>
public class RequestHistoryQueryTests
{
    private static string CaptureSql()
    {
        using var db = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer("Server=unused;Database=unused;Trusted_Connection=True;TrustServerCertificate=True")
            .Options);
        return RequestQueryService.HistoryOf(db.RequestStatusHistory.AsNoTracking(), 42).ToQueryString();
    }

    [Fact]
    public void History_IsFilteredByRequestInTheDatabase()
    {
        var sql = CaptureSql();

        Assert.Contains("WHERE", sql);
        Assert.Contains("[RequestId]", sql);
    }

    [Fact]
    public void History_IsOrderedNewestFirst_WithIdAsTieBreaker()
    {
        var sql = CaptureSql();

        var orderBy = sql[sql.IndexOf("ORDER BY", StringComparison.Ordinal)..];
        Assert.True(
            orderBy.IndexOf("[ChangedAt] DESC", StringComparison.Ordinal) < orderBy.IndexOf("[Id] DESC", StringComparison.Ordinal),
            orderBy);
    }

    [Fact]
    public void History_SelectsOnlyTheDtoColumns()
    {
        var select = CaptureSql().Split("FROM", 2)[0];

        foreach (var column in new[] { "Id", "RequestId", "PreviousStatus", "NewStatus", "ChangedAt", "ChangedBy" })
        {
            Assert.Contains($"[{column}]", select);
        }
    }
}
