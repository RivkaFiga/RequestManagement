namespace RequestManagement.Core.Domain;

/// <summary>
/// Audit record of one status change. Written in the same transaction as the change itself.
/// </summary>
public sealed class RequestStatusHistoryEntry
{
    public const int ChangedByMaxLength = 100;

    public long Id { get; set; }

    public int RequestId { get; set; }

    public RequestStatus PreviousStatus { get; set; }

    public RequestStatus NewStatus { get; set; }

    /// <summary>UTC, millisecond precision.</summary>
    public DateTime ChangedAt { get; set; }

    public required string ChangedBy { get; set; }

    public Request? Request { get; set; }
}
