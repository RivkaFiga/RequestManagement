using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace RequestManagement.Infrastructure.Persistence;

/// <summary>
/// <c>datetime2</c> carries no time zone, so values read back would have
/// <see cref="DateTimeKind.Unspecified"/>. Every timestamp in this schema is UTC;
/// this marks it as such so it serializes with a "Z" suffix.
/// </summary>
internal sealed class UtcDateTimeConverter()
    : ValueConverter<DateTime, DateTime>(
        toProvider => toProvider,
        fromProvider => DateTime.SpecifyKind(fromProvider, DateTimeKind.Utc));
