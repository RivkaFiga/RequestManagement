using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>Read model returned by the API. Entities never leave the data layer.</summary>
public sealed record RequestDto(
    int Id,
    string Title,
    string OrganizationName,
    RequestStatus Status,
    RequestPriority Priority,
    string? AssignedTo,
    DateTime CreatedAt,
    DateTime UpdatedAt,
    string RowVersion,
    IReadOnlyList<RequestStatus> AllowedNextStatuses);
