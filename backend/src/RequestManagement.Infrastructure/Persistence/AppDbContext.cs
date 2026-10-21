using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;

namespace RequestManagement.Infrastructure.Persistence;

public sealed class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Request> Requests => Set<Request>();

    public DbSet<RequestStatusHistoryEntry> RequestStatusHistory => Set<RequestStatusHistoryEntry>();

    protected override void OnModelCreating(ModelBuilder modelBuilder) =>
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(AppDbContext).Assembly);

    protected override void ConfigureConventions(ModelConfigurationBuilder configurationBuilder)
    {
        // All timestamps are UTC: datetime2(3) in the database, DateTimeKind.Utc when read back.
        configurationBuilder.Properties<DateTime>()
            .HavePrecision(3)
            .HaveConversion<UtcDateTimeConverter>();
    }
}
