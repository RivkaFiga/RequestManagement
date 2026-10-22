using System.Linq.Expressions;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;

namespace RequestManagement.Infrastructure.Requests;

/// <summary>
/// Server-side projection target (only the needed columns are selected) and the one place that maps a
/// request to <see cref="RequestDto"/>. Shared by the read and the write side.
/// </summary>
internal sealed record RequestRow(
    int Id,
    string Title,
    string OrganizationName,
    RequestStatus Status,
    RequestPriority Priority,
    string? AssignedTo,
    DateTime CreatedAt,
    DateTime UpdatedAt,
    byte[] Version)
{
    public static readonly Expression<Func<Request, RequestRow>> Projection = r => new RequestRow(
        r.Id, r.Title, r.OrganizationName, r.Status, r.Priority, r.AssignedTo, r.CreatedAt, r.UpdatedAt, r.Version);

    private static readonly Func<Request, RequestRow> Compiled = Projection.Compile();

    public static RequestRow From(Request request) => Compiled(request);

    public RequestDto ToDto(StatusTransitionPolicy policy) => new(
        Id,
        Title,
        OrganizationName,
        Status,
        Priority,
        AssignedTo,
        CreatedAt,
        UpdatedAt,
        Convert.ToBase64String(Version),
        policy.GetAllowedNextStatuses(Status));
}
