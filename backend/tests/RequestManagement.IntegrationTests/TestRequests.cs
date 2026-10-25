using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// Helpers for integration tests that own their rows (plan §6.2): apply the migrations to an isolated database
/// and insert requests that no other test reads or asserts on.
/// </summary>
public static class TestRequests
{
    public static AppDbContext CreateContext(string connectionString) =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseSqlServer(connectionString).Options);

    public static async Task MigrateAsync(string connectionString)
    {
        await using var db = CreateContext(connectionString);
        await db.Database.MigrateAsync();
    }

    /// <summary>Inserts <paramref name="count"/> requests with unique titles and returns them with their database-assigned ids and versions.</summary>
    public static async Task<List<Request>> CreateAsync(
        string connectionString,
        string titlePrefix,
        RequestStatus status = RequestStatus.New,
        RequestPriority priority = RequestPriority.Medium,
        int count = 1)
    {
        var now = DateTime.UtcNow.AddDays(-1);
        var created = new DateTime(now.Ticks - now.Ticks % TimeSpan.TicksPerMillisecond, DateTimeKind.Utc);
        var requests = Enumerable.Range(0, count).Select(_ => new Request
        {
            Title = $"{titlePrefix} {Guid.NewGuid():N}",
            OrganizationName = $"{titlePrefix} Ltd",
            Status = status,
            Priority = priority,
            CreatedAt = created,
            UpdatedAt = created,
        }).ToList();

        await using var db = CreateContext(connectionString);
        db.Requests.AddRange(requests);
        await db.SaveChangesAsync();
        return requests;
    }
}
