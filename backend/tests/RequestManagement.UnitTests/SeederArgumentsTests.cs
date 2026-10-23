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

    private const string PerfServer = "localhost,1433";
    private const string PerfDatabase = "RequestManagement_Perf";

    private static SeederArguments ParseCreateNew(params string[] extra)
    {
        string[] args = ["--create-new", "--expect-server", PerfServer, "--expect-database", PerfDatabase, .. extra];
        Assert.True(SeederArguments.TryParse(args, out var parsed, out var error), error);
        return parsed;
    }

    [Fact]
    public void CreateNewWithExpectedTarget_IsParsed()
    {
        var parsed = ParseCreateNew("--count", "100000");

        Assert.True(parsed.CreateNew);
        Assert.False(parsed.Reset);
        Assert.Equal(PerfServer, parsed.ExpectServer);
        Assert.Equal(PerfDatabase, parsed.ExpectDatabase);
    }

    [Theory]
    [InlineData("--create-new")]
    [InlineData("--create-new", "--expect-database", "RequestManagement_Perf")]
    [InlineData("--expect-server", "localhost,1433")]
    [InlineData("--expect-database", "RequestManagement_Perf")]
    [InlineData("--expect-database")]
    [InlineData("--expect-database", "--count")]
    [InlineData("--create-new", "--reset", "--expect-server", "localhost,1433", "--expect-database", "RequestManagement_Perf")]
    public void InvalidTargetOptions_AreErrors(params string[] args)
    {
        Assert.False(SeederArguments.TryParse(args, out _, out var error));
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Theory]
    [InlineData("Server=localhost,1433;Database=RequestManagement")]
    [InlineData("Server=localhost,1433;Database=RequestManagement_SeedCheck")]
    [InlineData("Server=localhost,1433;Database=requestmanagement_perf")]
    [InlineData("Server=localhost,1434;Database=RequestManagement_Perf")]
    [InlineData("Server=LOCALHOST,1433;Database=RequestManagement_Perf")]
    [InlineData("Server=sql.example.com,1433;Database=RequestManagement_Perf")]
    public void ExpectedTarget_MustMatchExactly(string connectionString)
    {
        Assert.NotNull(SeederArguments.CheckExpectedTarget(ParseCreateNew(), new SqlConnectionStringBuilder(connectionString)));
    }

    [Fact]
    public void ExpectedTarget_ExactMatch_IsAllowed()
    {
        var connection = new SqlConnectionStringBuilder("Server=localhost,1433;Database=RequestManagement_Perf");

        Assert.Null(SeederArguments.CheckExpectedTarget(ParseCreateNew(), connection));
    }

    [Theory]
    [InlineData(null, "Server=localhost,1433;Database=RequestManagement_Perf")]
    [InlineData("", "Server=localhost,1433;Database=RequestManagement_Perf")]
    [InlineData("  ", "Server=localhost,1433;Database=RequestManagement_Perf")]
    [InlineData("Server=localhost,1433;Database=RequestManagement_Perf", "Server=localhost,1433;Database=RequestManagement")]
    public void ExpectedTarget_NeedsTheEnvironmentVariable_ToBeTheConnectionInUse(string? environmentValue, string configuredValue)
    {
        Assert.NotNull(SeederArguments.CheckExplicitEnvironmentVariable(ParseCreateNew(), environmentValue, configuredValue));
    }

    [Fact]
    public void ExpectedTarget_WithMatchingEnvironmentVariable_IsAllowed()
    {
        const string value = "Server=localhost,1433;Database=RequestManagement_Perf";

        Assert.Null(SeederArguments.CheckExplicitEnvironmentVariable(ParseCreateNew(), value, value));
    }

    [Fact]
    public void WithoutExpectations_NothingChanges()
    {
        Assert.True(SeederArguments.TryParse(["--reset"], out var parsed, out _));
        var other = new SqlConnectionStringBuilder("Server=elsewhere;Database=Anything");

        Assert.False(parsed.CreateNew);
        Assert.Null(SeederArguments.CheckExpectedTarget(parsed, other));
        Assert.Null(SeederArguments.CheckExplicitEnvironmentVariable(parsed, null, "x"));
    }
}
