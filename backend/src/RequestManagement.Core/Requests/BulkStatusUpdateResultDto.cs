namespace RequestManagement.Core.Requests;

/// <summary>
/// Response of <c>POST /api/requests/bulk-status</c> (plan §4.2, decision D2: Partial Success). It is returned with
/// 200 whenever the call itself was valid, even if every item failed. <see cref="Results"/> has one entry per
/// requested item, in the order they were sent; <c>Requested = Succeeded + Failed</c>.
/// </summary>
public sealed record BulkStatusUpdateResultDto(
    int Requested,
    int Succeeded,
    int Failed,
    IReadOnlyList<BulkStatusItemResultDto> Results)
{
    public static BulkStatusUpdateResultDto From(IReadOnlyList<BulkStatusItemResultDto> results)
    {
        var succeeded = results.Count(r => r.Outcome == StatusUpdateOutcome.Updated);
        return new BulkStatusUpdateResultDto(results.Count, succeeded, results.Count - succeeded, results);
    }
}

/// <summary>
/// The outcome for one item. <see cref="RowVersion"/> is the new version after <see cref="StatusUpdateOutcome.Updated"/>
/// and the current version after <see cref="StatusUpdateOutcome.Conflict"/> (so the client can retry); otherwise
/// <c>null</c>. <see cref="Error"/> explains a failure and is <c>null</c> after an update.
/// </summary>
public sealed record BulkStatusItemResultDto(
    int Id,
    StatusUpdateOutcome Outcome,
    string? RowVersion,
    string? Error)
{
    public static BulkStatusItemResultDto From(int id, StatusUpdateResult result) => new(
        id,
        result.Outcome,
        result.Outcome == StatusUpdateOutcome.Updated ? result.Request!.RowVersion : result.CurrentRowVersion,
        result.Error);
}
