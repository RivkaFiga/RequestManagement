using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace RequestManagement.Infrastructure.Persistence;

/// <summary>
/// Used only by the <c>dotnet ef</c> tools. <c>migrations add</c> never connects, so a
/// placeholder is enough; <c>database update</c> takes the real connection string from the
/// <c>ConnectionStrings__RequestManagement</c> environment variable or <c>--connection</c>.
/// </summary>
public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<AppDbContext>
{
    private const string PlaceholderConnectionString =
        "Server=localhost,1433;Database=RequestManagement;TrustServerCertificate=True";

    public AppDbContext CreateDbContext(string[] args)
    {
        var connectionString =
            Environment.GetEnvironmentVariable("ConnectionStrings__RequestManagement")
            ?? PlaceholderConnectionString;

        var options = new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer(connectionString)
            .Options;

        return new AppDbContext(options);
    }
}
