namespace RequestManagement.Infrastructure.Seeding;

/// <summary>
/// Inputs that fully determine the generated data set. The same values always produce
/// the same rows (including Ids), independent of <see cref="BatchSize"/>.
/// </summary>
public sealed record SeedOptions
{
    public const int DefaultCount = 100_000;
    public const int MaxCount = 5_000_000;
    public const int DefaultBatchSize = 10_000;
    public const int MinBatchSize = 100;
    public const int MaxBatchSize = 100_000;
    public const int DefaultRandomSeed = 20261020;

    /// <summary>Fixed reference date: CreatedAt values lie in the 24 months before it.</summary>
    public static readonly DateTime DefaultAnchorUtc = new(2026, 10, 1, 0, 0, 0, DateTimeKind.Utc);

    public int Count { get; init; } = DefaultCount;

    public int BatchSize { get; init; } = DefaultBatchSize;

    public int RandomSeed { get; init; } = DefaultRandomSeed;

    public DateTime AnchorUtc { get; init; } = DefaultAnchorUtc;

    public void Validate()
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(Count, 1, nameof(Count));
        ArgumentOutOfRangeException.ThrowIfGreaterThan(Count, MaxCount, nameof(Count));
        ArgumentOutOfRangeException.ThrowIfLessThan(BatchSize, MinBatchSize, nameof(BatchSize));
        ArgumentOutOfRangeException.ThrowIfGreaterThan(BatchSize, MaxBatchSize, nameof(BatchSize));
        if (AnchorUtc.Kind != DateTimeKind.Utc || AnchorUtc.Ticks % TimeSpan.TicksPerMillisecond != 0)
        {
            // Whole milliseconds, so every generated value round-trips through datetime2(3) unchanged.
            throw new ArgumentException("The anchor date must be UTC with whole-millisecond precision.", nameof(AnchorUtc));
        }
    }
}
