using RequestManagement.Core.Domain;

namespace RequestManagement.Infrastructure.Seeding;

/// <summary>
/// What is in the database after seeding. <see cref="Checksum"/> is a quick fingerprint
/// (CHECKSUM_AGG over the business columns) for comparing two runs; it is not cryptographic.
/// </summary>
public sealed record SeedReport(
    long RequestCount,
    long HistoryCount,
    IReadOnlyDictionary<RequestStatus, int> ByStatus,
    IReadOnlyDictionary<RequestPriority, int> ByPriority,
    int? Checksum);
