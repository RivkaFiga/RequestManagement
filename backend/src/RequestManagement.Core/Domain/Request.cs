namespace RequestManagement.Core.Domain;

/// <summary>
/// A service request handled on behalf of an organization.
/// </summary>
public sealed class Request
{
    public const int TitleMaxLength = 200;
    public const int OrganizationNameMaxLength = 200;
    public const int AssignedToMaxLength = 100;

    public int Id { get; set; }

    public required string Title { get; set; }

    public required string OrganizationName { get; set; }

    public RequestStatus Status { get; set; }

    public RequestPriority Priority { get; set; }

    /// <summary>Handler id or name; <c>null</c> while unassigned (assumption A3).</summary>
    public string? AssignedTo { get; set; }

    /// <summary>UTC, millisecond precision.</summary>
    public DateTime CreatedAt { get; set; }

    /// <summary>UTC, millisecond precision. Never earlier than <see cref="CreatedAt"/>.</summary>
    public DateTime UpdatedAt { get; set; }

    /// <summary>
    /// Concurrency token. Maintained by the database (SQL Server <c>rowversion</c>) and
    /// changed on every update, so a competing update with a stale value is rejected.
    /// </summary>
    public byte[] Version { get; set; } = [];

    public ICollection<RequestStatusHistoryEntry> StatusHistory { get; } = new List<RequestStatusHistoryEntry>();
}
