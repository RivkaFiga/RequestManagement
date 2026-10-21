using RequestManagement.Core.Requests;

namespace RequestManagement.UnitTests;

public class ChangedByTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void MissingHeader_DefaultsToAnonymous(string? header)
    {
        Assert.True(ChangedBy.TryResolve(header, out var value, out var error));
        Assert.Equal("anonymous", value);
        Assert.Null(error);
    }

    [Fact]
    public void Header_IsTrimmed()
    {
        Assert.True(ChangedBy.TryResolve("  dana  ", out var value, out _));
        Assert.Equal("dana", value);
    }

    [Fact]
    public void HundredCharacters_AreAccepted() =>
        Assert.True(ChangedBy.TryResolve(new string('n', 100), out _, out _));

    [Fact]
    public void OverHundredCharacters_AreRejected()
    {
        Assert.False(ChangedBy.TryResolve(new string('n', 101), out _, out var error));
        Assert.Contains("100", error);
    }
}
