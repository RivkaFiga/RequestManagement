namespace RequestManagement.Infrastructure.Requests;

/// <summary>Configuration section <c>SummaryCache</c> (plan §4.5, R7.2).</summary>
public sealed class SummaryCacheOptions
{
    public const string SectionName = "SummaryCache";

    /// <summary>
    /// Turns the cache off. It exists only so the uncached path can be measured (B2) and tested; leave it on otherwise.
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary>How long a computed summary is served before it is recomputed. Must be greater than 0.</summary>
    public int ExpirationSeconds { get; set; } = 60;
}
