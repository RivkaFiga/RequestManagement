namespace RequestManagement.Core.Requests;

/// <summary>The whitelisted sort fields of the list endpoint (plan §4.2).</summary>
public enum RequestSortField
{
    CreatedAt,
    UpdatedAt,
    Priority,
    Status,
    Title,
}
