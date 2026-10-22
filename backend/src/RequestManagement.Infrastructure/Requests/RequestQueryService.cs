using System.Linq.Expressions;
using Microsoft.EntityFrameworkCore;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.Infrastructure.Requests;

/// <summary>
/// Search and lookup of requests. One composed <see cref="IQueryable{T}"/> is translated to SQL:
/// WHERE (filters), ORDER BY, OFFSET/FETCH and a COUNT over the same predicate.
/// Nothing is materialized before paging; entities are never tracked or returned (R1.1, R1.9).
/// </summary>
public sealed class RequestQueryService(
    AppDbContext db, StatusTransitionPolicy policy, TimeProvider clock, RequestSummaryCache summaryCache) : IRequestQueryService
{
    private const string LikeEscape = "\\";

    public async Task<PagedResult<RequestDto>> SearchAsync(RequestSearchQuery query, CancellationToken ct)
    {
        var filtered = ApplyFilters(db.Requests.AsNoTracking(), query);

        var totalCount = await filtered.CountAsync(ct);

        var skip = (long)(query.Page - 1) * query.PageSize;
        if (skip >= totalCount)
        {
            // Beyond the last page (this also avoids int overflow in Skip).
            return new PagedResult<RequestDto>([], query.Page, query.PageSize, totalCount);
        }

        var rows = await ApplySort(filtered, query.SortField, query.SortDescending)
            .Skip((int)skip)
            .Take(query.PageSize)
            .Select(RequestRow.Projection)
            .ToListAsync(ct);

        return new PagedResult<RequestDto>(rows.ConvertAll(row => row.ToDto(policy)), query.Page, query.PageSize, totalCount);
    }

    public async Task<RequestDto?> GetByIdAsync(int id, CancellationToken ct)
    {
        var row = await db.Requests.AsNoTracking()
            .Where(r => r.Id == id)
            .Select(RequestRow.Projection)
            .SingleOrDefaultAsync(ct);

        return row?.ToDto(policy);
    }

    public async Task<IReadOnlyList<StatusHistoryEntryDto>?> GetHistoryAsync(int id, CancellationToken ct)
    {
        if (!await db.Requests.AnyAsync(r => r.Id == id, ct))
        {
            return null;
        }

        return await HistoryOf(db.RequestStatusHistory.AsNoTracking(), id).ToListAsync(ct);
    }

    /// <summary>
    /// The history of one request, newest first. <c>Id</c> breaks ties between changes with the same timestamp,
    /// so the order is deterministic. Internal so the SQL shape can be asserted in tests.
    /// </summary>
    internal static IQueryable<StatusHistoryEntryDto> HistoryOf(IQueryable<RequestStatusHistoryEntry> history, int requestId) =>
        history
            .Where(h => h.RequestId == requestId)
            .OrderByDescending(h => h.ChangedAt)
            .ThenByDescending(h => h.Id)
            .Select(h => new StatusHistoryEntryDto(h.Id, h.RequestId, h.PreviousStatus, h.NewStatus, h.ChangedAt, h.ChangedBy));

    /// <summary>Served from <see cref="RequestSummaryCache"/>; on a miss it is computed by <see cref="ComputeSummaryAsync"/>.</summary>
    public Task<RequestSummaryDto> GetSummaryAsync(CancellationToken ct) =>
        summaryCache.GetOrCreateAsync(ComputeSummaryAsync, ct);

    private async Task<RequestSummaryDto> ComputeSummaryAsync(CancellationToken ct)
    {
        // Two GROUP BY queries executed by SQL Server; only one small row per group is transferred (A4, R1.6).
        var byStatus = await CountByStatus(db.Requests.AsNoTracking()).ToListAsync(ct);
        var byPriority = await CountByPriority(db.Requests.AsNoTracking()).ToListAsync(ct);

        return BuildSummary(byStatus, byPriority, clock.GetUtcNow().UtcDateTime);
    }

    /// <summary>SELECT Status, COUNT(*) ... GROUP BY Status. Internal so the SQL shape can be asserted in tests.</summary>
    internal static IQueryable<StatusCountDto> CountByStatus(IQueryable<Request> requests) =>
        requests.GroupBy(r => r.Status).Select(g => new StatusCountDto(g.Key, g.Count()));

    /// <summary>SELECT Priority, COUNT(*) ... GROUP BY Priority.</summary>
    internal static IQueryable<PriorityCountDto> CountByPriority(IQueryable<Request> requests) =>
        requests.GroupBy(r => r.Priority).Select(g => new PriorityCountDto(g.Key, g.Count()));

    /// <summary>Adds the groups that have no rows (count 0), orders by enum value and derives the total.</summary>
    internal static RequestSummaryDto BuildSummary(
        IReadOnlyList<StatusCountDto> byStatus, IReadOnlyList<PriorityCountDto> byPriority, DateTime generatedAt)
    {
        var statuses = Enum.GetValues<RequestStatus>()
            .Select(status => new StatusCountDto(status, byStatus.Where(c => c.Status == status).Sum(c => c.Count)))
            .ToList();
        var priorities = Enum.GetValues<RequestPriority>()
            .Select(priority => new PriorityCountDto(priority, byPriority.Where(c => c.Priority == priority).Sum(c => c.Count)))
            .ToList();

        return new RequestSummaryDto(statuses.Sum(c => c.Count), statuses, priorities, generatedAt);
    }

    /// <summary>The filtered, unsorted, unpaged query. Internal so the SQL shape can be asserted in tests.</summary>
    internal static IQueryable<Request> ApplyFilters(IQueryable<Request> requests, RequestSearchQuery query)
    {
        if (query.Search?.Trim() is { Length: > 0 } search)
        {
            var pattern = $"%{EscapeLike(search)}%";
            requests = requests.Where(r =>
                EF.Functions.Like(r.Title, pattern, LikeEscape)
                || EF.Functions.Like(r.OrganizationName, pattern, LikeEscape));
        }

        if (query.Status is { Length: > 0 })
        {
            var statuses = query.Status.Distinct().ToArray();
            requests = requests.Where(r => statuses.Contains(r.Status));
        }

        if (query.Priority is { Length: > 0 })
        {
            var priorities = query.Priority.Distinct().ToArray();
            requests = requests.Where(r => priorities.Contains(r.Priority));
        }

        if (!string.IsNullOrWhiteSpace(query.OrganizationName))
        {
            var prefix = $"{EscapeLike(query.OrganizationName.Trim())}%";
            requests = requests.Where(r => EF.Functions.Like(r.OrganizationName, prefix, LikeEscape));
        }

        if (!string.IsNullOrWhiteSpace(query.AssignedTo))
        {
            var assignedTo = query.AssignedTo.Trim();
            requests = requests.Where(r => r.AssignedTo == assignedTo);
        }

        if (query.CreatedFrom is { } from)
        {
            var fromUtc = from.UtcDateTime;
            requests = requests.Where(r => r.CreatedAt >= fromUtc);
        }

        if (query.CreatedTo is { } to)
        {
            var toUtc = to.UtcDateTime;
            requests = requests.Where(r => r.CreatedAt < toUtc);
        }

        return requests;
    }

    /// <summary>Whitelisted sort with Id as the deterministic tie-breaker (same direction, decision D8).</summary>
    internal static IOrderedQueryable<Request> ApplySort(IQueryable<Request> requests, RequestSortField field, bool descending) =>
        field switch
        {
            RequestSortField.UpdatedAt => Order(requests, r => r.UpdatedAt, descending),
            RequestSortField.Priority => Order(requests, r => r.Priority, descending),
            RequestSortField.Status => Order(requests, r => r.Status, descending),
            RequestSortField.Title => Order(requests, r => r.Title, descending),
            _ => Order(requests, r => r.CreatedAt, descending),
        };

    /// <summary>Escapes LIKE wildcards so user input is matched literally (assumption A5).</summary>
    internal static string EscapeLike(string value) =>
        value
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("%", "\\%", StringComparison.Ordinal)
            .Replace("_", "\\_", StringComparison.Ordinal)
            .Replace("[", "\\[", StringComparison.Ordinal);

    private static IOrderedQueryable<Request> Order<TKey>(
        IQueryable<Request> requests, Expression<Func<Request, TKey>> key, bool descending) =>
        descending
            ? requests.OrderByDescending(key).ThenByDescending(r => r.Id)
            : requests.OrderBy(key).ThenBy(r => r.Id);
}
