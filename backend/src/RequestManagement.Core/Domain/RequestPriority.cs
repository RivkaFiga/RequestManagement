namespace RequestManagement.Core.Domain;

/// <summary>
/// Request priority. Values are ordinal (Low &lt; Medium &lt; High) so that sorting by the
/// stored <c>tinyint</c> sorts by importance. Enforced by a CHECK constraint (1-3).
/// </summary>
public enum RequestPriority : byte
{
    Low = 1,
    Medium = 2,
    High = 3,
}
