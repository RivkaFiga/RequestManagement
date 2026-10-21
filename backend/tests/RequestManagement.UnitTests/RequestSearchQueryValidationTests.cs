using System.ComponentModel.DataAnnotations;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;

namespace RequestManagement.UnitTests;

/// <summary>UT-2: validation of the search query (R1.5, R1.7, R8.3).</summary>
public class RequestSearchQueryValidationTests
{
    private static List<ValidationResult> Validate(RequestSearchQuery query)
    {
        var results = new List<ValidationResult>();
        Validator.TryValidateObject(query, new ValidationContext(query), results, validateAllProperties: true);
        return results;
    }

    private static string[] InvalidMembers(RequestSearchQuery query) =>
        Validate(query).SelectMany(r => r.MemberNames).Distinct().ToArray();

    [Fact]
    public void DefaultQuery_IsValid_WithDocumentedDefaults()
    {
        var query = new RequestSearchQuery();

        Assert.Empty(Validate(query));
        Assert.Equal(1, query.Page);
        Assert.Equal(20, query.PageSize);
        Assert.Equal(RequestSortField.CreatedAt, query.SortField);
        Assert.True(query.SortDescending);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(101)]
    [InlineData(500)]
    public void PageSize_OutsideOneToOneHundred_IsRejected(int pageSize) =>
        Assert.Equal(new[] { "pageSize" }, InvalidMembers(new RequestSearchQuery { PageSize = pageSize }));

    [Theory]
    [InlineData(1)]
    [InlineData(100)]
    public void PageSize_AtTheBounds_IsAccepted(int pageSize) =>
        Assert.Empty(Validate(new RequestSearchQuery { PageSize = pageSize }));

    [Theory]
    [InlineData(0)]
    [InlineData(-5)]
    public void Page_BelowOne_IsRejected(int page) =>
        Assert.Equal(new[] { "page" }, InvalidMembers(new RequestSearchQuery { Page = page }));

    [Theory]
    [InlineData("bogus")]
    [InlineData("id")]
    [InlineData("createdAt; DROP TABLE Requests")]
    [InlineData("organizationName")]
    public void UnknownSortBy_IsRejected(string sortBy) =>
        Assert.Equal(new[] { "sortBy" }, InvalidMembers(new RequestSearchQuery { SortBy = sortBy }));

    [Theory]
    [InlineData("createdAt", RequestSortField.CreatedAt)]
    [InlineData("updatedAt", RequestSortField.UpdatedAt)]
    [InlineData("priority", RequestSortField.Priority)]
    [InlineData("status", RequestSortField.Status)]
    [InlineData("title", RequestSortField.Title)]
    [InlineData("TITLE", RequestSortField.Title)]
    [InlineData(null, RequestSortField.CreatedAt)]
    public void WhitelistedSortBy_IsAccepted_AndParsed(string? sortBy, RequestSortField expected)
    {
        var query = new RequestSearchQuery { SortBy = sortBy };

        Assert.Empty(Validate(query));
        Assert.Equal(expected, query.SortField);
    }

    [Theory]
    [InlineData("up")]
    [InlineData("ascending")]
    public void UnknownSortDirection_IsRejected(string direction) =>
        Assert.Equal(new[] { "sortDirection" }, InvalidMembers(new RequestSearchQuery { SortDirection = direction }));

    [Theory]
    [InlineData("asc", false)]
    [InlineData("ASC", false)]
    [InlineData("desc", true)]
    [InlineData(null, true)]
    public void SortDirection_IsParsed(string? direction, bool descending)
    {
        var query = new RequestSearchQuery { SortDirection = direction };

        Assert.Empty(Validate(query));
        Assert.Equal(descending, query.SortDescending);
    }

    [Fact]
    public void CreatedFrom_AfterCreatedTo_IsRejected()
    {
        var query = new RequestSearchQuery
        {
            CreatedFrom = new DateTimeOffset(2026, 5, 2, 0, 0, 0, TimeSpan.Zero),
            CreatedTo = new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero),
        };

        Assert.Equal(new[] { "createdFrom" }, InvalidMembers(query));
    }

    [Fact]
    public void CreatedFrom_EqualToCreatedTo_IsAccepted()
    {
        var moment = new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero);

        Assert.Empty(Validate(new RequestSearchQuery { CreatedFrom = moment, CreatedTo = moment }));
    }

    [Theory]
    [InlineData((byte)0)]
    [InlineData((byte)5)]
    [InlineData((byte)7)]
    public void UndefinedStatusValue_IsRejected(byte value) =>
        Assert.Equal(new[] { "status" }, InvalidMembers(new RequestSearchQuery { Status = [RequestStatus.New, (RequestStatus)value] }));

    [Theory]
    [InlineData((byte)0)]
    [InlineData((byte)4)]
    public void UndefinedPriorityValue_IsRejected(byte value) =>
        Assert.Equal(new[] { "priority" }, InvalidMembers(new RequestSearchQuery { Priority = [(RequestPriority)value] }));

    [Fact]
    public void DefinedEnumValues_AreAccepted() =>
        Assert.Empty(Validate(new RequestSearchQuery
        {
            Status = [RequestStatus.New, RequestStatus.Completed],
            Priority = [RequestPriority.Low, RequestPriority.High],
        }));

    [Theory]
    [InlineData("a")]
    [InlineData(" a ")]
    [InlineData("   ")]
    public void TooShortSearch_IsRejected(string search) =>
        Assert.Equal(new[] { "search" }, InvalidMembers(new RequestSearchQuery { Search = search }));

    [Fact]
    public void TooLongSearch_IsRejected() =>
        Assert.Equal(new[] { "search" }, InvalidMembers(new RequestSearchQuery { Search = new string('x', 101) }));

    [Theory]
    [InlineData(2)]
    [InlineData(100)]
    public void SearchWithinLimits_IsAccepted(int length) =>
        Assert.Empty(Validate(new RequestSearchQuery { Search = new string('x', length) }));

    [Fact]
    public void OverlongTextFilters_AreRejected()
    {
        var query = new RequestSearchQuery
        {
            OrganizationName = new string('o', Request.OrganizationNameMaxLength + 1),
            AssignedTo = new string('a', Request.AssignedToMaxLength + 1),
        };

        Assert.Equal(new[] { "organizationName", "assignedTo" }, InvalidMembers(query));
    }

    [Fact]
    public void AllProblemsAreReportedTogether()
    {
        var query = new RequestSearchQuery { Page = 0, PageSize = 0, SortBy = "nope", Search = "x" };

        Assert.Equal(new[] { "page", "pageSize", "search", "sortBy" }, InvalidMembers(query));
    }
}
