namespace RequestManagement.Core.Requests;

/// <summary>Read side of the requests API (the Api → Infrastructure boundary, decision D4).</summary>
public interface IRequestQueryService
{
    /// <summary>Runs a validated search; filtering, sorting and paging are executed by the database.</summary>
    Task<PagedResult<RequestDto>> SearchAsync(RequestSearchQuery query, CancellationToken ct);

    /// <summary>Returns the request, or <c>null</c> when it does not exist.</summary>
    Task<RequestDto?> GetByIdAsync(int id, CancellationToken ct);

    /// <summary>Counts all requests by status and by priority (two server-side GROUP BY queries) plus the total.</summary>
    Task<RequestSummaryDto> GetSummaryAsync(CancellationToken ct);
}
