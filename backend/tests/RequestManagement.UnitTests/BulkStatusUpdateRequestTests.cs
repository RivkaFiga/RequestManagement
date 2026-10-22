using System.ComponentModel.DataAnnotations;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;

namespace RequestManagement.UnitTests;

/// <summary>UT-3: validation of the bulk envelope (T-207, R4.1, R8.3) and the shape of the bulk result.</summary>
public class BulkStatusUpdateRequestTests
{
    private static readonly string ValidRowVersion = Convert.ToBase64String([0, 0, 0, 0, 0, 0, 0x07, 0xD1]);

    private static BulkStatusUpdateItem Item(int id, string? rowVersion = null) =>
        new() { Id = id, RowVersion = rowVersion ?? ValidRowVersion };

    private static BulkStatusUpdateRequest Request(int itemCount) => new()
    {
        Status = RequestStatus.InProgress,
        Items = Enumerable.Range(1, itemCount).Select(id => (BulkStatusUpdateItem?)Item(id)).ToList(),
    };

    private static List<ValidationResult> Validate(BulkStatusUpdateRequest request)
    {
        var results = new List<ValidationResult>();
        Validator.TryValidateObject(request, new ValidationContext(request), results, validateAllProperties: true);
        return results;
    }

    private static string[] InvalidMembers(BulkStatusUpdateRequest request) =>
        Validate(request).SelectMany(r => r.MemberNames).Distinct().ToArray();

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(99)]
    [InlineData(100)]
    public void OneToOneHundredItems_AreAccepted(int count) =>
        Assert.Empty(Validate(Request(count)));

    [Theory]
    [InlineData(101)]
    [InlineData(1000)]
    public void MoreThanOneHundredItems_AreRejected(int count)
    {
        var error = Assert.Single(Validate(Request(count)));

        Assert.Equal(new[] { "items" }, error.MemberNames);
        Assert.Contains("100", error.ErrorMessage);
        Assert.Contains(count.ToString(), error.ErrorMessage);
    }

    [Fact]
    public void NoItems_AreRejected()
    {
        Assert.Equal(new[] { "items" }, InvalidMembers(Request(0)));
        Assert.Equal(new[] { "items" }, InvalidMembers(new BulkStatusUpdateRequest { Status = RequestStatus.Waiting }));
    }

    [Fact]
    public void DuplicateIds_AreRejected_AndNamed()
    {
        var request = Request(3);
        request.Items!.Add(Item(2));
        request.Items.Add(Item(3));

        var error = Assert.Single(Validate(request));

        Assert.Equal(new[] { "items" }, error.MemberNames);
        Assert.Contains("2, 3", error.ErrorMessage);
    }

    [Fact]
    public void MissingStatus_IsRejected() =>
        Assert.Equal(new[] { "status" }, InvalidMembers(new BulkStatusUpdateRequest { Items = [Item(1)] }));

    [Theory]
    [InlineData(0)]
    [InlineData(5)]
    [InlineData(200)]
    public void UndefinedStatusValue_IsRejected(byte value) =>
        Assert.Equal(
            new[] { "status" },
            InvalidMembers(new BulkStatusUpdateRequest { Status = (RequestStatus)value, Items = [Item(1)] }));

    [Fact]
    public void NullItem_IsRejected_ByIndex() =>
        Assert.Equal(
            new[] { "items[1]" },
            InvalidMembers(new BulkStatusUpdateRequest { Status = RequestStatus.Waiting, Items = [Item(1), null] }));

    [Fact]
    public void ItemWithoutId_IsRejected_ByIndex() =>
        Assert.Equal(
            new[] { "items[0].id" },
            InvalidMembers(new BulkStatusUpdateRequest
            {
                Status = RequestStatus.Waiting,
                Items = [new BulkStatusUpdateItem { RowVersion = ValidRowVersion }],
            }));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not base64!")]
    [InlineData("AAAAAAAAB")]
    public void MissingOrMalformedRowVersion_IsRejected_ByIndex(string? rowVersion) =>
        Assert.Equal(
            new[] { "items[1].rowVersion" },
            InvalidMembers(new BulkStatusUpdateRequest
            {
                Status = RequestStatus.Waiting,
                Items = [Item(1), new BulkStatusUpdateItem { Id = 2, RowVersion = rowVersion }],
            }));

    [Fact]
    public void AllProblemsAreReportedTogether()
    {
        var request = new BulkStatusUpdateRequest
        {
            Items = [Item(1), Item(1), null, new BulkStatusUpdateItem { Id = 4, RowVersion = "x!" }],
        };

        Assert.Equal(
            new[] { "status", "items[2]", "items[3].rowVersion", "items" },
            InvalidMembers(request));
    }

    [Fact]
    public void Changes_ExposeIdsAndDecodedVersions_InTheOrderSent()
    {
        var request = new BulkStatusUpdateRequest
        {
            Status = RequestStatus.Waiting,
            Items = [Item(9), Item(3, Convert.ToBase64String([1, 2, 3]))],
        };

        Assert.Empty(Validate(request));
        Assert.Equal([9, 3], request.Changes.Select(c => c.Id));
        Assert.Equal(new byte[] { 1, 2, 3 }, request.Changes[1].RowVersion);
    }

    [Fact]
    public void Changes_DoesNotThrowOnAnInvalidRequest()
    {
        // MVC reads every public property while validating, so this must be safe before the request is known valid.
        var request = new BulkStatusUpdateRequest
        {
            Items = [Item(1), null, new BulkStatusUpdateItem { RowVersion = "x!" }, new BulkStatusUpdateItem { Id = 4 }],
        };

        Assert.Equal([1, 4], request.Changes.Select(c => c.Id));
        Assert.Empty(new BulkStatusUpdateRequest().Changes);
    }

    [Fact]
    public void Result_CountsSuccessesAndFailures_AndKeepsTheOrder()
    {
        var item = (int id, StatusUpdateOutcome outcome) => new BulkStatusItemResultDto(id, outcome, null, null);

        var result = BulkStatusUpdateResultDto.From(
        [
            item(5, StatusUpdateOutcome.Updated),
            item(2, StatusUpdateOutcome.Conflict),
            item(9, StatusUpdateOutcome.Updated),
            item(1, StatusUpdateOutcome.NotFound),
            item(7, StatusUpdateOutcome.InvalidTransition),
        ]);

        Assert.Equal(5, result.Requested);
        Assert.Equal(2, result.Succeeded);
        Assert.Equal(3, result.Failed);
        Assert.Equal([5, 2, 9, 1, 7], result.Results.Select(r => r.Id));
    }

    [Fact]
    public void ItemResult_CarriesTheNewVersionWhenUpdated_AndTheCurrentVersionOnConflict()
    {
        var dto = new RequestDto(
            1, "t", "o", RequestStatus.Waiting, RequestPriority.Low, null, DateTime.UtcNow, DateTime.UtcNow, "NEWVER==", []);

        var updated = BulkStatusItemResultDto.From(1, StatusUpdateResult.Updated(dto));
        var conflict = BulkStatusItemResultDto.From(2, StatusUpdateResult.Conflict(RequestStatus.Waiting, "CURRENT=="));
        var missing = BulkStatusItemResultDto.From(3, StatusUpdateResult.NotFound(3));
        var rejected = BulkStatusItemResultDto.From(4, StatusUpdateResult.InvalidTransition("no"));

        Assert.Equal(("NEWVER==", null), (updated.RowVersion, updated.Error));
        Assert.Equal("CURRENT==", conflict.RowVersion);
        Assert.NotNull(conflict.Error);
        Assert.Null(missing.RowVersion);
        Assert.Contains("3", missing.Error);
        Assert.Equal((null, "no"), (rejected.RowVersion, rejected.Error));
    }
}
