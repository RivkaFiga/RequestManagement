using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>How a status update ended. The values double as the per-item outcomes of the bulk endpoint (plan §4.2).</summary>
public enum StatusUpdateOutcome
{
    Updated,
    NotFound,
    Conflict,
    InvalidTransition,
}

/// <summary>
/// Result of one status update. <see cref="Request"/> is set when <see cref="StatusUpdateOutcome.Updated"/>;
/// <see cref="CurrentStatus"/> and <see cref="CurrentRowVersion"/> when <see cref="StatusUpdateOutcome.Conflict"/>
/// (what the row looks like now, so the client can reload); <see cref="Error"/> for the two rejections.
/// </summary>
public sealed record StatusUpdateResult(
    StatusUpdateOutcome Outcome,
    RequestDto? Request = null,
    RequestStatus? CurrentStatus = null,
    string? CurrentRowVersion = null,
    string? Error = null)
{
    public static StatusUpdateResult Updated(RequestDto request) =>
        new(StatusUpdateOutcome.Updated, Request: request);

    public static StatusUpdateResult NotFound(int id) =>
        new(StatusUpdateOutcome.NotFound, Error: $"No request with id {id} exists.");

    public static StatusUpdateResult Conflict(RequestStatus currentStatus, string currentRowVersion) =>
        new(StatusUpdateOutcome.Conflict, CurrentStatus: currentStatus, CurrentRowVersion: currentRowVersion,
            Error: "The request was changed by someone else. Reload it and try again.");

    public static StatusUpdateResult InvalidTransition(string error) =>
        new(StatusUpdateOutcome.InvalidTransition, Error: error);
}
