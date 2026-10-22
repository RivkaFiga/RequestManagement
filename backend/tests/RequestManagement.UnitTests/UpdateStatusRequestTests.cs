using System.ComponentModel.DataAnnotations;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;

namespace RequestManagement.UnitTests;

/// <summary>Validation of the PATCH status body (T-205, R2.2, R8.3).</summary>
public class UpdateStatusRequestTests
{
    private static readonly string ValidRowVersion = Convert.ToBase64String([0, 0, 0, 0, 0, 0, 0x07, 0xD1]);

    private static string[] InvalidMembers(UpdateStatusRequest request)
    {
        var results = new List<ValidationResult>();
        Validator.TryValidateObject(request, new ValidationContext(request), results, validateAllProperties: true);
        return results.SelectMany(r => r.MemberNames).Distinct().ToArray();
    }

    [Fact]
    public void ValidRequest_HasNoErrors_AndExposesTheDecodedRowVersion()
    {
        var request = new UpdateStatusRequest { Status = RequestStatus.InProgress, RowVersion = ValidRowVersion };

        Assert.Empty(InvalidMembers(request));
        Assert.Equal(new byte[] { 0, 0, 0, 0, 0, 0, 0x07, 0xD1 }, request.RowVersionBytes);
    }

    [Fact]
    public void MissingStatus_IsRejected() =>
        Assert.Equal(new[] { "status" }, InvalidMembers(new UpdateStatusRequest { RowVersion = ValidRowVersion }));

    [Theory]
    [InlineData(0)]
    [InlineData(5)]
    [InlineData(200)]
    public void UndefinedStatusValue_IsRejected(byte value) =>
        Assert.Equal(
            new[] { "status" },
            InvalidMembers(new UpdateStatusRequest { Status = (RequestStatus)value, RowVersion = ValidRowVersion }));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not base64!")]
    [InlineData("AAAAAAAAB")]
    public void MissingOrMalformedRowVersion_IsRejected(string? rowVersion) =>
        Assert.Equal(
            new[] { "rowVersion" },
            InvalidMembers(new UpdateStatusRequest { Status = RequestStatus.Waiting, RowVersion = rowVersion }));

    [Fact]
    public void AllProblemsAreReportedTogether() =>
        Assert.Equal(new[] { "status", "rowVersion" }, InvalidMembers(new UpdateStatusRequest()));
}
