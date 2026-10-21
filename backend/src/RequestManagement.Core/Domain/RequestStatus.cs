namespace RequestManagement.Core.Domain;

/// <summary>
/// Lifecycle status of a request. Stored as <c>tinyint</c>; explicit values keep the
/// stored numbers stable and are enforced by a CHECK constraint (1-4).
/// </summary>
public enum RequestStatus : byte
{
    New = 1,
    InProgress = 2,
    Waiting = 3,
    Completed = 4,
}
