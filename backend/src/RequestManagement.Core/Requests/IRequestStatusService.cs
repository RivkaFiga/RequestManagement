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
}
