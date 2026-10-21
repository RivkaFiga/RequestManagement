using System.ComponentModel.DataAnnotations;
using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>
/// Query parameters of <c>GET /api/requests</c> (plan §4.2). All rules live in
/// <see cref="Validate"/> so that every problem is reported together, keyed by the
/// query-string parameter name (decision D5: one validation mechanism).
/// </summary>
public sealed class RequestSearchQuery : IValidatableObject
{
    public const int DefaultPage = 1;
    public const int DefaultPageSize = 20;
    public const int MaxPageSize = 100;
    public const int SearchMinLength = 2;
    public const int SearchMaxLength = 100;

    public int Page { get; set; } = DefaultPage;

    public int PageSize { get; set; } = DefaultPageSize;

    /// <summary>Case-insensitive contains over Title or OrganizationName (A5).</summary>
    public string? Search { get; set; }

    public RequestStatus[]? Status { get; set; }

    public RequestPriority[]? Priority { get; set; }

    /// <summary>Starts-with (A6).</summary>
    public string? OrganizationName { get; set; }

    /// <summary>Exact match (A6).</summary>
    public string? AssignedTo { get; set; }

    /// <summary>Inclusive lower bound on CreatedAt (A7).</summary>
    public DateTimeOffset? CreatedFrom { get; set; }

    /// <summary>Exclusive upper bound on CreatedAt (A7).</summary>
    public DateTimeOffset? CreatedTo { get; set; }

    /// <summary><c>createdAt</c> (default), <c>updatedAt</c>, <c>priority</c>, <c>status</c> or <c>title</c>.</summary>
    public string? SortBy { get; set; }

    /// <summary><c>asc</c> or <c>desc</c> (default <c>desc</c>).</summary>
    public string? SortDirection { get; set; }

    /// <summary>The effective sort field. Meaningful once the query is valid.</summary>
    public RequestSortField SortField =>
        TryParseSortField(SortBy, out var sortField) ? sortField : RequestSortField.CreatedAt;

    /// <summary>The effective direction. Meaningful once the query is valid.</summary>
    public bool SortDescending =>
        !string.Equals(SortDirection?.Trim(), "asc", StringComparison.OrdinalIgnoreCase);

    public static bool TryParseSortField(string? value, out RequestSortField field)
    {
        field = RequestSortField.CreatedAt;
        if (string.IsNullOrWhiteSpace(value))
        {
            return true; // default
        }

        foreach (var candidate in Enum.GetValues<RequestSortField>())
        {
            if (string.Equals(candidate.ToString(), value.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                field = candidate;
                return true;
            }
        }

        return false;
    }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (Page < 1)
        {
            yield return Error("page", "Page must be at least 1.");
        }

        if (PageSize is < 1 or > MaxPageSize)
        {
            yield return Error("pageSize", $"PageSize must be between 1 and {MaxPageSize}.");
        }

        if (Search is not null)
        {
            var length = Search.Trim().Length;
            if (length is < SearchMinLength or > SearchMaxLength)
            {
                yield return Error("search", $"Search must be between {SearchMinLength} and {SearchMaxLength} characters.");
            }
        }

        if (Status?.Any(s => !Enum.IsDefined(s)) == true)
        {
            yield return Error("status", "Status contains an undefined value.");
        }

        if (Priority?.Any(p => !Enum.IsDefined(p)) == true)
        {
            yield return Error("priority", "Priority contains an undefined value.");
        }

        if (OrganizationName is { Length: > Request.OrganizationNameMaxLength })
        {
            yield return Error("organizationName", $"OrganizationName must be at most {Request.OrganizationNameMaxLength} characters.");
        }

        if (AssignedTo is { Length: > Request.AssignedToMaxLength })
        {
            yield return Error("assignedTo", $"AssignedTo must be at most {Request.AssignedToMaxLength} characters.");
        }

        if (CreatedFrom is { } from && CreatedTo is { } to && from > to)
        {
            yield return Error("createdFrom", "CreatedFrom must not be later than CreatedTo.");
        }

        if (!TryParseSortField(SortBy, out _))
        {
            var allowed = string.Join(", ", Enum.GetNames<RequestSortField>().Select(n => char.ToLowerInvariant(n[0]) + n[1..]));
            yield return Error("sortBy", $"SortBy must be one of: {allowed}.");
        }

        if (!string.IsNullOrWhiteSpace(SortDirection)
            && !string.Equals(SortDirection.Trim(), "asc", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(SortDirection.Trim(), "desc", StringComparison.OrdinalIgnoreCase))
        {
            yield return Error("sortDirection", "SortDirection must be 'asc' or 'desc'.");
        }
    }

    private static ValidationResult Error(string member, string message) => new(message, [member]);
}
