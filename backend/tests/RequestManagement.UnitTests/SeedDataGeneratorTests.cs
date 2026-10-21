using RequestManagement.Core.Domain;
using RequestManagement.Infrastructure.Seeding;

namespace RequestManagement.UnitTests;

public class SeedDataGeneratorTests
{
    private static readonly SeedOptions Small = new() { Count = 5_000 };

    [Fact]
    public void SameOptions_ProduceIdenticalRows()
    {
        var first = SeedDataGenerator.Generate(Small).Select(Fingerprint).ToList();
        var second = SeedDataGenerator.Generate(Small).Select(Fingerprint).ToList();

        Assert.Equal(first, second);
    }

    [Fact]
    public void DifferentSeed_ProducesDifferentRows()
    {
        var first = SeedDataGenerator.Generate(Small).Select(Fingerprint).ToList();
        var other = SeedDataGenerator.Generate(Small with { RandomSeed = Small.RandomSeed + 1 }).Select(Fingerprint).ToList();

        Assert.NotEqual(first, other);
    }

    [Fact]
    public void LargerCount_StartsWithTheSameRows()
    {
        // A prefix property: --count 100 and --count 100000 agree on the first 100 rows.
        var shortRun = SeedDataGenerator.Generate(Small with { Count = 100 }).Select(Fingerprint);
        var longRun = SeedDataGenerator.Generate(Small).Take(100).Select(Fingerprint);

        Assert.Equal(shortRun, longRun);
    }

    [Fact]
    public void Ids_AreSequentialFromOne()
    {
        var ids = SeedDataGenerator.Generate(Small).Select(r => r.Id);

        Assert.Equal(Enumerable.Range(1, Small.Count), ids);
    }

    [Fact]
    public void Generation_IsLazy_SoCallersControlMemory()
    {
        // Asking for the maximum count but taking 3 rows must not materialize the rest.
        var rows = SeedDataGenerator.Generate(new SeedOptions { Count = SeedOptions.MaxCount }).Take(3).ToList();

        Assert.Equal(3, rows.Count);
    }

    [Fact]
    public void EveryRow_SatisfiesTheSchemaConstraints()
    {
        var anchor = Small.AnchorUtc;
        var earliest = anchor.AddDays(-SeedDataGenerator.HistoryWindowDays);

        foreach (var r in SeedDataGenerator.Generate(Small))
        {
            Assert.InRange(r.Title.Length, 1, Request.TitleMaxLength);
            Assert.InRange(r.OrganizationName.Length, 1, Request.OrganizationNameMaxLength);
            Assert.True(r.AssignedTo is null || r.AssignedTo.Length <= Request.AssignedToMaxLength);
            Assert.True(Enum.IsDefined(r.Status));
            Assert.True(Enum.IsDefined(r.Priority));

            Assert.Equal(DateTimeKind.Utc, r.CreatedAt.Kind);
            Assert.Equal(DateTimeKind.Utc, r.UpdatedAt.Kind);
            Assert.InRange(r.CreatedAt, earliest, anchor);
            Assert.InRange(r.UpdatedAt, r.CreatedAt, anchor);
            Assert.Equal(0, r.CreatedAt.Ticks % TimeSpan.TicksPerMillisecond); // fits datetime2(3) exactly
            Assert.Equal(0, r.UpdatedAt.Ticks % TimeSpan.TicksPerMillisecond);
            if (r.Status == RequestStatus.New)
            {
                Assert.Equal(r.CreatedAt, r.UpdatedAt);
            }
        }
    }

    [Fact]
    public void Distribution_FollowsTheDesignedSkew()
    {
        var rows = SeedDataGenerator.Generate(new SeedOptions { Count = 20_000 }).ToList();
        double Share(Func<Request, bool> predicate) => rows.Count(predicate) * 100.0 / rows.Count;

        Assert.InRange(Share(r => r.AssignedTo is null), 13, 17);
        Assert.InRange(Share(r => r.Status == RequestStatus.New), 18, 22);
        Assert.InRange(Share(r => r.Status == RequestStatus.InProgress), 28, 32);
        Assert.InRange(Share(r => r.Status == RequestStatus.Waiting), 13, 17);
        Assert.InRange(Share(r => r.Status == RequestStatus.Completed), 33, 37);
        Assert.InRange(Share(r => r.Priority == RequestPriority.High), 13, 17);

        Assert.InRange(rows.Select(r => r.AssignedTo).Distinct().Count(), 2, SeedDataGenerator.HandlerCount + 1);
        Assert.True(rows.Select(r => r.OrganizationName).Distinct().Count() > 1_000);
    }

    [Fact]
    public void Vocabulary_HasAbout2000Organizations()
    {
        Assert.Equal(2_000, SeedDataGenerator.OrganizationCount);
    }

    [Theory]
    [InlineData(0, SeedOptions.DefaultBatchSize)]
    [InlineData(SeedOptions.MaxCount + 1, SeedOptions.DefaultBatchSize)]
    [InlineData(100, SeedOptions.MinBatchSize - 1)]
    [InlineData(100, SeedOptions.MaxBatchSize + 1)]
    public void InvalidOptions_AreRejected(int count, int batchSize)
    {
        var options = new SeedOptions { Count = count, BatchSize = batchSize };

        Assert.Throws<ArgumentOutOfRangeException>(() => SeedDataGenerator.Generate(options));
    }

    [Fact]
    public void NonUtcAnchor_IsRejected()
    {
        var options = new SeedOptions { AnchorUtc = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Local) };

        Assert.Throws<ArgumentException>(() => SeedDataGenerator.Generate(options));
    }

    private static string Fingerprint(Request r) =>
        $"{r.Id}|{r.Title}|{r.OrganizationName}|{r.Status}|{r.Priority}|{r.AssignedTo}|{r.CreatedAt:O}|{r.UpdatedAt:O}";
}
