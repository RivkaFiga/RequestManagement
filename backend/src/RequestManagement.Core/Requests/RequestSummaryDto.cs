using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>Number of requests in one <see cref="RequestStatus"/>.</summary>
public sealed record StatusCountDto(RequestStatus Status, int Count);

/// <summary>Number of requests with one <see cref="RequestPriority"/>.</summary>
public sealed record PriorityCountDto(RequestPriority Priority, int Count);

/// <summary>
/// Global aggregations (assumption A4): they ignore the list filters. Every defined status and priority is
/// listed (with a count of 0 when unused), in enum order, so the shape is stable. Each list sums to <see cref="Total"/>.
/// </summary>
public sealed record RequestSummaryDto(
    int Total,
    IReadOnlyList<StatusCountDto> ByStatus,
    IReadOnlyList<PriorityCountDto> ByPriority,
    DateTime GeneratedAt);
