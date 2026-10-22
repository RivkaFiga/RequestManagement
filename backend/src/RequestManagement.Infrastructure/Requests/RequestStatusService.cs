using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.Infrastructure.Requests;

/// <summary>
/// Status changes with optimistic concurrency and an audit trail (plan §4.4).
/// <para>
/// The row is loaded, the client's <c>rowVersion</c> is compared with it, and the change is saved as
/// <c>UPDATE ... WHERE Id = @id AND Version = @loadedVersion</c>. Because the loaded version equals the client's,
/// a competing commit between the load and the save affects 0 rows, EF Core throws
/// <see cref="DbUpdateConcurrencyException"/> and the update is reported as a conflict: a stale write never persists.
/// </para>
/// <para>
/// The request update and the history <c>INSERT</c> are one <c>SaveChangesAsync</c>, i.e. one database transaction:
/// if either statement fails, both are rolled back.
/// </para>
/// </summary>
public sealed class RequestStatusService(
    AppDbContext db,
    StatusTransitionPolicy policy,
    TimeProvider clock,
    RequestSummaryCache summaryCache,
    ILogger<RequestStatusService> logger) : IRequestStatusService
{
    public async Task<StatusUpdateResult> UpdateStatusAsync(
        int id, RequestStatus newStatus, byte[] rowVersion, string changedBy, CancellationToken ct)
    {
        var request = await db.Requests.SingleOrDefaultAsync(r => r.Id == id, ct);
        if (request is null)
        {
            return StatusUpdateResult.NotFound(id);
        }

        var result = await ApplyAsync(request, newStatus, rowVersion, changedBy, ct);
        if (result.Outcome == StatusUpdateOutcome.Updated)
        {
            summaryCache.Invalidate(); // after the commit (plan §4.5)
        }

        return result;
    }

    public async Task<BulkStatusUpdateResultDto> BulkUpdateStatusAsync(
        RequestStatus newStatus, IReadOnlyList<BulkStatusChange> changes, string changedBy, CancellationToken ct)
    {
        // One query for all rows; a missing id is simply absent from the result.
        var ids = changes.Select(c => c.Id).Distinct().ToArray();
        if (ids.Length != changes.Count)
        {
            // Request validation rejects duplicates with 400; a repeated id would otherwise act on a stale entity.
            throw new ArgumentException("Item ids must be distinct.", nameof(changes));
        }

        var loaded = await db.Requests.Where(r => ids.Contains(r.Id)).ToDictionaryAsync(r => r.Id, ct);

        // Each item goes through the single-update logic and has its own SaveChanges (its own transaction), so a
        // conflict or a rejection affects that item only.
        var results = new List<BulkStatusItemResultDto>(changes.Count);
        var anyUpdated = false;
        try
        {
            foreach (var change in changes)
            {
                var result = loaded.TryGetValue(change.Id, out var request)
                    ? await ApplyAsync(request, newStatus, change.RowVersion, changedBy, ct)
                    : StatusUpdateResult.NotFound(change.Id);
                anyUpdated |= result.Outcome == StatusUpdateOutcome.Updated;
                results.Add(BulkStatusItemResultDto.From(change.Id, result));
            }
        }
        finally
        {
            // Once, after the commits (plan §4.4). In a finally so that an unexpected failure part-way through the
            // batch cannot leave a cached summary that predates the items already committed.
            if (anyUpdated)
            {
                summaryCache.Invalidate();
            }
        }

        var summary = BulkStatusUpdateResultDto.From(results);
        logger.LogInformation(
            "Bulk status update to {To} by {ChangedBy}: {Requested} requested, {Succeeded} updated, " +
            "{NotFound} not found, {Conflicts} conflicts, {Rejected} transitions not allowed.",
            newStatus, changedBy, summary.Requested, summary.Succeeded,
            results.Count(r => r.Outcome == StatusUpdateOutcome.NotFound),
            results.Count(r => r.Outcome == StatusUpdateOutcome.Conflict),
            results.Count(r => r.Outcome == StatusUpdateOutcome.InvalidTransition));
        return summary;
    }

    /// <summary>The per-request logic: compare versions, check the transition, save the change with its history row.</summary>
    private async Task<StatusUpdateResult> ApplyAsync(
        Request request, RequestStatus newStatus, byte[] rowVersion, string changedBy, CancellationToken ct)
    {
        var id = request.Id;
        if (!request.Version.AsSpan().SequenceEqual(rowVersion))
        {
            logger.LogInformation("Status update of request {RequestId} rejected: stale row version.", id);
            return StatusUpdateResult.Conflict(request.Status, Convert.ToBase64String(request.Version));
        }

        var previous = request.Status;
        if (!policy.CanTransition(previous, newStatus))
        {
            logger.LogInformation("Status update of request {RequestId} rejected: {From} to {To} is not allowed.",
                id, previous, newStatus);
            return StatusUpdateResult.InvalidTransition(DescribeRejectedTransition(previous, newStatus));
        }

        // datetime2(3): keep the value we return identical to the value the database stores.
        var now = TruncateToMilliseconds(clock.GetUtcNow().UtcDateTime);
        request.Status = newStatus;
        request.UpdatedAt = now > request.UpdatedAt ? now : request.UpdatedAt; // never moves backwards
        var historyEntry = new RequestStatusHistoryEntry
        {
            RequestId = id,
            PreviousStatus = previous,
            NewStatus = newStatus,
            ChangedAt = now,
            ChangedBy = changedBy,
        };
        db.RequestStatusHistory.Add(historyEntry);

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            // Nothing was written. Stop tracking this item's pending changes so they cannot be saved later.
            db.Entry(historyEntry).State = EntityState.Detached;
            db.Entry(request).State = EntityState.Detached;
            logger.LogInformation("Status update of request {RequestId} lost a concurrent update.", id);
            return await ConflictAsync(id, ct);
        }

        logger.LogInformation("Request {RequestId} changed from {From} to {To} by {ChangedBy}.",
            id, previous, newStatus, changedBy);
        return StatusUpdateResult.Updated(RequestRow.From(request).ToDto(policy));
    }

    /// <summary>Reports the row as it is now; the request may even have been deleted in the meantime.</summary>
    private async Task<StatusUpdateResult> ConflictAsync(int id, CancellationToken ct)
    {
        var current = await db.Requests.AsNoTracking()
            .Where(r => r.Id == id)
            .Select(r => new { r.Status, r.Version })
            .SingleOrDefaultAsync(ct);

        return current is null
            ? StatusUpdateResult.NotFound(id)
            : StatusUpdateResult.Conflict(current.Status, Convert.ToBase64String(current.Version));
    }

    private string DescribeRejectedTransition(RequestStatus from, RequestStatus to)
    {
        var allowed = policy.GetAllowedNextStatuses(from);
        var allowedText = allowed.Count == 0
            ? $"{from} is final."
            : $"Allowed from {from}: {string.Join(", ", allowed)}.";
        return $"Cannot change the status from {from} to {to}. {allowedText}";
    }

    private static DateTime TruncateToMilliseconds(DateTime value) =>
        new(value.Ticks - value.Ticks % TimeSpan.TicksPerMillisecond, DateTimeKind.Utc);
}
