using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>Write side of the requests API (the Api → Infrastructure boundary, decision D4).</summary>
public interface IRequestStatusService
{
    /// <summary>
    /// Changes the status of a request if <paramref name="rowVersion"/> is still current and the transition is allowed.
    /// The change and its history entry are saved atomically.
    /// </summary>
    Task<StatusUpdateResult> UpdateStatusAsync(
        int id, RequestStatus newStatus, byte[] rowVersion, string changedBy, CancellationToken ct);

    /// <summary>
    /// Partial Success (decision D2): applies the same rules as <see cref="UpdateStatusAsync"/> to every item, each in
    /// its own transaction, and reports one outcome per item in the order given. One failing item never prevents or
    /// rolls back another. Unexpected failures (e.g. the database becomes unavailable) are not item outcomes: they
    /// propagate, and items committed before the failure stay committed.
    /// </summary>
    Task<BulkStatusUpdateResultDto> BulkUpdateStatusAsync(
        RequestStatus newStatus, IReadOnlyList<BulkStatusChange> changes, string changedBy, CancellationToken ct);
}
