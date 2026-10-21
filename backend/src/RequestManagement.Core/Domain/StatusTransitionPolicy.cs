namespace RequestManagement.Core.Domain;

/// <summary>
/// The single source of the allowed status transitions (assumption A1):
/// New → InProgress | Waiting; InProgress → Waiting | Completed;
/// Waiting → InProgress | Completed. Completed is terminal and
/// setting the same status again is not a transition.
/// Stateless and thread-safe.
/// </summary>
public sealed class StatusTransitionPolicy
{
    private static readonly IReadOnlyDictionary<RequestStatus, RequestStatus[]> AllowedTransitions =
        new Dictionary<RequestStatus, RequestStatus[]>
        {
            [RequestStatus.New] = [RequestStatus.InProgress, RequestStatus.Waiting],
            [RequestStatus.InProgress] = [RequestStatus.Waiting, RequestStatus.Completed],
            [RequestStatus.Waiting] = [RequestStatus.InProgress, RequestStatus.Completed],
            [RequestStatus.Completed] = [],
        };

    public IReadOnlyList<RequestStatus> GetAllowedNextStatuses(RequestStatus current) =>
        AllowedTransitions.TryGetValue(current, out var next) ? next : [];

    public bool CanTransition(RequestStatus from, RequestStatus to) =>
        GetAllowedNextStatuses(from).Contains(to);
}
