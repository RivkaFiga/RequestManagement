using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>One recorded status change of a request (plan §4.2).</summary>
public sealed record StatusHistoryEntryDto(
    long Id,
    int RequestId,
    RequestStatus PreviousStatus,
    RequestStatus NewStatus,
    DateTime ChangedAt,
    string ChangedBy);
