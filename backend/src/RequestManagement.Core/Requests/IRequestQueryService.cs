namespace RequestManagement.Core.Requests;

/// <summary>Read side of the requests API (the Api → Infrastructure boundary, decision D4).</summary>
public interface IRequestQueryService
{
    /// <summary>Runs a validated search; filtering, sorting and paging are executed by the database.</summary>
    Task<PagedResult<RequestDto>> SearchAsync(RequestSearchQuery query, CancellationToken ct);

    /// <summary>Returns the request, or <c>null</c> when it does not exist.</summary>
    Task<RequestDto?> GetByIdAsync(int id, CancellationToken ct);

    /// <summary>
    /// Returns the status changes of the request, newest first (ties broken by the newest entry id),
    /// or <c>null</c> when the request does not exist. A request without changes yields an empty list.
    /// </summary>
    Task<IReadOnlyList<StatusHistoryEntryDto>?> GetHistoryAsync(int id, CancellationToken ct);

    /// <summary>
    /// Counts all requests by status and by priority (two server-side GROUP BY queries) plus the total. The result is
    /// cached for a short time and dropped after every successful status change (T-208).
    /// </summary>
    Task<RequestSummaryDto> GetSummaryAsync(CancellationToken ct);
}
