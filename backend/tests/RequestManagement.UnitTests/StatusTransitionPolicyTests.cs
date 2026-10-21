using RequestManagement.Core.Domain;

namespace RequestManagement.UnitTests;

public class StatusTransitionPolicyTests
{
    private readonly StatusTransitionPolicy _policy = new();

    // All 16 (from, to) pairs, assumption A1.
    [Theory]
    [InlineData(RequestStatus.New, RequestStatus.New, false)]
    [InlineData(RequestStatus.New, RequestStatus.InProgress, true)]
    [InlineData(RequestStatus.New, RequestStatus.Waiting, true)]
    [InlineData(RequestStatus.New, RequestStatus.Completed, false)]
    [InlineData(RequestStatus.InProgress, RequestStatus.New, false)]
    [InlineData(RequestStatus.InProgress, RequestStatus.InProgress, false)]
    [InlineData(RequestStatus.InProgress, RequestStatus.Waiting, true)]
    [InlineData(RequestStatus.InProgress, RequestStatus.Completed, true)]
    [InlineData(RequestStatus.Waiting, RequestStatus.New, false)]
    [InlineData(RequestStatus.Waiting, RequestStatus.InProgress, true)]
    [InlineData(RequestStatus.Waiting, RequestStatus.Waiting, false)]
    [InlineData(RequestStatus.Waiting, RequestStatus.Completed, true)]
    [InlineData(RequestStatus.Completed, RequestStatus.New, false)]
    [InlineData(RequestStatus.Completed, RequestStatus.InProgress, false)]
    [InlineData(RequestStatus.Completed, RequestStatus.Waiting, false)]
    [InlineData(RequestStatus.Completed, RequestStatus.Completed, false)]
    public void CanTransition_MatchesTheDefinedRules(RequestStatus from, RequestStatus to, bool expected)
    {
        Assert.Equal(expected, _policy.CanTransition(from, to));
        Assert.Equal(expected, _policy.GetAllowedNextStatuses(from).Contains(to));
    }

    [Fact]
    public void UndefinedStatus_HasNoAllowedTransitions()
    {
        Assert.Empty(_policy.GetAllowedNextStatuses((RequestStatus)99));
    }
}
