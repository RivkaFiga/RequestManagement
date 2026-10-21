using Microsoft.Data.SqlClient;
using RequestManagement.Infrastructure.Seeding;
using RequestManagement.Seeder;

namespace RequestManagement.UnitTests;

public class SeederArgumentsTests
{
    [Fact]
    public void NoArguments_UseSafeDefaults()
    {
        Assert.True(SeederArguments.TryParse([], out var parsed, out _));

        Assert.Equal(SeedOptions.DefaultCount, parsed.Options.Count);
        Assert.Equal(SeedOptions.DefaultBatchSize, parsed.Options.BatchSize);
        Assert.Equal(SeedOptions.DefaultRandomSeed, parsed.Options.RandomSeed);
        Assert.False(parsed.Reset); // destructive mode is never the default
    }

    [Fact]
    public void AllOptions_AreParsed()
    {
        Assert.True(SeederArguments.TryParse(
            ["--reset", "--count", "150000", "--batch-size", "5000", "--seed", "7"], out var parsed, out _));

        Assert.True(parsed.Reset);
        Assert.Equal(150_000, parsed.Options.Count);
        Assert.Equal(5_000, parsed.Options.BatchSize);
        Assert.Equal(7, parsed.Options.RandomSeed);
    }

    [Theory]
    [InlineData("--count")]
    [InlineData("--count", "abc")]
    [InlineData("--count", "0")]
    [InlineData("--batch-size", "10")]
    [InlineData("--rest")]
    public void InvalidArguments_AreErrors(params string[] args)
    {
        Assert.False(SeederArguments.TryParse(args, out _, out var error));
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("Production")]
    [InlineData("Staging")]
    public void OutsideDevelopment_IsRefused(string? environment)
    {
        var connection = new SqlConnectionStringBuilder("Server=localhost;Database=RequestManagement");

        Assert.NotNull(SeederArguments.CheckSafety(environment, connection));
    }

    [Theory]
    [InlineData("Server=localhost")]
    [InlineData("Server=localhost;Database=master")]
    [InlineData("Server=localhost;Database=TempDB")]
    public void MissingOrSystemDatabase_IsRefused(string connectionString)
    {
        Assert.NotNull(SeederArguments.CheckSafety("Development", new SqlConnectionStringBuilder(connectionString)));
    }

    [Fact]
    public void DevelopmentWithNamedDatabase_IsAllowed()
    {
        var connection = new SqlConnectionStringBuilder("Server=localhost;Database=RequestManagement");

        Assert.Null(SeederArguments.CheckSafety("Development", connection));
    }
}
